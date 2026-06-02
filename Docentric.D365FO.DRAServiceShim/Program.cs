using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.ServiceProcess;
using CommandLine;

// =============================================================================
// Docentric.D365FO.DRAServiceShim -- per-instance data path injector for the DRA Windows Service
// =============================================================================
//
// PROBLEM
// -------
// Multiple DRA instances on the same server all write to the same log file:
//   C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing\
// This causes System.IO.IOException (file locking) on every write.
//
// ROOT CAUSE
// ----------
// FileManager.get_AppDataDirectory() calls:
//   Environment.GetFolderPath(SpecialFolder.CommonApplicationData)
// which calls the Win32 SHGetFolderPath(CSIDL_COMMON_APPDATA) API.
// This reads HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders.
// It is a machine-wide value that cannot be overridden per-process via:
//   - NSSM AppEnvironmentExtra
//   - sc.exe Environment registry block
//   - Any environment variable injection
//
// WHY THE SETTER WORKS
// --------------------
// get_AppDataDirectory() caches the resolved path in a private field:
//
//   if (IsNullOrWhiteSpace(appDataDirectory)) {
//       appDataDirectory = GetFolderPath(0x23) + "Microsoft" + "...Document Routing"
//   }
//   return appDataDirectory;
//
// set_AppDataDirectory() (internal/assembly visibility) writes that same field.
// If we call set_AppDataDirectory() BEFORE any code reads AppDataDirectory,
// the IsNullOrWhiteSpace check is false and GetFolderPath is NEVER called.
// The custom path is used for every subsequent operation:
//   - Log file path
//   - Config file path
//   - TokenCache2.dat directory
//   - ExcludedPrintersSet.xml path
//   - Logs\ subdirectory
//
// HOW THIS SHIM WORKS
// -------------------
// 1. Reads DRA_DATA_PATH from the --DRA_DATA_PATH command-line argument and falls
//    back to the DRA_DATA_PATH process environment variable.
// 2. Pre-creates the per-instance data directory and its Logs\ subdirectory so that
//    the DRA service never encounters a missing path on first write.
// 3. Forces FileManager.Instance to be created (triggers the double-checked locking
//    singleton) and then calls FileManager.set_AppDataDirectory(dataPath) via
//    reflection on that instance, overriding the cached machine-wide path before any
//    service code can read it.
// 4. Loads Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe as a managed
//    assembly from the same directory, instantiates its ServiceBase subclass, and
//    calls ServiceBase.Run() to hand control to the SCM.
// 5. On any startup failure, writes a detailed error entry to the Windows Application
//    Event Log (source "DocentricDRAServiceShim") and re-throws so the SCM records a
//    non-zero exit code.
//
// DEPLOYMENT
// ----------
// - Place DraShim.exe in each per-instance DRA binary directory alongside Service.exe.
// - Register the service with sc.exe pointing to DraShim.exe (not Service.exe).
// - Set DRA_DATA_PATH in the service Environment registry key:
//     HKLM\SYSTEM\CurrentControlSet\Services\<Name>\Environment
//     REG_MULTI_SZ: DRA_DATA_PATH=C:\DRAData\DRA1
//   Alternatively pass it as a command-line argument:
//     binPath= "C:\...\DraShim.exe --DRA_DATA_PATH=C:\DRAData\DRA1"
//
// COMPATIBILITY
// -------------
// - Target: .NET Framework 4.8, x86 (matches Service.exe)
// - NuGet dependency: CommandLineParser
// - Uses only mscorlib + System.ServiceProcess

namespace Docentric.D365FO.DRAServiceShim
{
    /// <summary>
    /// Entry point for the DRA Service Shim.
    /// </summary>
    /// <remarks>
    /// This shim acts as a thin wrapper around the real DRA Windows Service
    /// (<c>Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe</c>).
    /// Its sole purpose is to inject a per-instance data directory into
    /// <c>FileManager.AppDataDirectory</c> via reflection before the service
    /// starts, preventing multiple DRA instances on the same machine from
    /// colliding on the shared <c>CommonApplicationData</c> path.
    /// </remarks>
    internal static class Program
    {
        /// <summary>
        /// Name of the environment variable (and the matching command-line option)
        /// that supplies the per-instance DRA data directory path.
        /// Set this in <c>HKLM\SYSTEM\CurrentControlSet\Services\&lt;Name&gt;\Environment</c>
        /// as a <c>REG_MULTI_SZ</c> value, e.g. <c>DRA_DATA_PATH=C:\DRAData\DRA1</c>.
        /// </summary>
        private const string DataPathEnvVar = "DRA_DATA_PATH";

        /// <summary>
        /// Assembly-qualified type name of the <see cref="System.ServiceProcess.ServiceBase"/>
        /// subclass that implements the DRA Windows Service, located inside
        /// <c>Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe</c>.
        /// </summary>
        private const string ServiceClassName =
            "Microsoft.Dynamics.AX.Framework.DocumentRouting.Service";

        /// <summary>
        /// Assembly-qualified type name of <c>FileManager</c> from the DRA Runtime assembly.
        /// The Runtime assembly must be present in the same directory as this shim so
        /// that the CLR can resolve it via normal AppDomain probing.
        /// </summary>
        private const string FileManagerTypeName =
            "Microsoft.Dynamics.AX.Framework.DocumentRouting.Runtime.FileManager, " +
            "Microsoft.Dynamics.AX.Framework.DocumentRouting.Runtime";

        /// <summary>
        /// Main entry point executed by the Service Control Manager when the service starts.
        /// </summary>
        /// <remarks>
        /// Performs the following steps in order:
        /// <list type="number">
        ///   <item><description>Resolves the per-instance data path from command-line args or the environment variable.</description></item>
        ///   <item><description>Pre-creates the data directory and its <c>Logs\</c> subdirectory.</description></item>
        ///   <item><description>Injects the resolved path into <c>FileManager.AppDataDirectory</c> via reflection.</description></item>
        ///   <item><description>Loads and runs the real DRA service, blocking until the SCM stops it.</description></item>
        /// </list>
        /// Any unhandled exception is written to the Windows Application Event Log before
        /// being re-thrown so that the SCM records a non-zero exit code.
        /// </remarks>
        /// <param name="args">Command-line arguments passed by the SCM or during manual invocation.</param>
        internal static void Main(string[] args)
        {
            try
            {
                string dataPath = ReadDataPath(args);
                EnsureDirectories(dataPath);
                InjectAppDataDirectory(dataPath);
                RunRealService();
            }
            catch (Exception ex)
            {
                WriteEventLogError(ex);
                throw; // let SCM record the non-zero exit
            }
        }

        // ── Step 1: read DRA_DATA_PATH from command line or environment ───────

        /// <summary>
        /// Resolves the per-instance DRA data path.
        /// </summary>
        /// <remarks>
        /// Resolution order:
        /// <list type="number">
        ///   <item><description>The <c>--DRA_DATA_PATH</c> command-line argument.</description></item>
        ///   <item><description>The <c>DRA_DATA_PATH</c> process environment variable.</description></item>
        /// </list>
        /// The returned path is always absolute (normalised via <see cref="Path.GetFullPath"/>).
        /// </remarks>
        /// <param name="args">Raw command-line arguments received by <see cref="Main"/>.</param>
        /// <returns>The absolute path to the per-instance DRA data directory.</returns>
        /// <exception cref="InvalidOperationException">
        /// Thrown when neither the command-line argument nor the environment variable is set,
        /// or when the command-line arguments cannot be parsed.
        /// </exception>
        private static string ReadDataPath(string[] args)
        {
            string raw = TryReadDataPathFromArgs(args);

            if (string.IsNullOrWhiteSpace(raw))
                raw = Environment.GetEnvironmentVariable(DataPathEnvVar);

            if (string.IsNullOrWhiteSpace(raw))
                throw new InvalidOperationException(
                    $"DRA data path is not set. Provide command-line argument " +
                    $"--{DataPathEnvVar}=C:\\DRAData\\<InstanceName> or set environment variable " +
                    $"'{DataPathEnvVar}' in HKLM\\SYSTEM\\CurrentControlSet\\Services\\<Name>\\Environment " +
                    $"as REG_MULTI_SZ value: {DataPathEnvVar}=C:\\DRAData\\<InstanceName>.");

            return Path.GetFullPath(raw.Trim());
        }

        /// <summary>
        /// Attempts to extract the data path from the <c>--DRA_DATA_PATH</c> command-line argument.
        /// </summary>
        /// <param name="args">Raw command-line arguments to parse.</param>
        /// <returns>
        /// The value of <c>--DRA_DATA_PATH</c>, or <see langword="null"/> / empty string if the
        /// argument was not supplied.
        /// </returns>
        /// <exception cref="InvalidOperationException">
        /// Thrown when the argument list is syntactically invalid (unrecognised tokens, etc.).
        /// </exception>
        private static string TryReadDataPathFromArgs(string[] args)
        {
            ParserResult<CommandLineOptions> parseResult =
                Parser.Default.ParseArguments<CommandLineOptions>(args ?? Array.Empty<string>());

            if (parseResult.Tag == ParserResultType.NotParsed)
            {
                IEnumerable<Error> errors =
                    ((NotParsed<CommandLineOptions>)parseResult).Errors;

                throw new InvalidOperationException(
                    $"Invalid command-line arguments for Docentric.D365FO.DRAServiceShim. " +
                    $"Use --{DataPathEnvVar}=C:\\DRAData\\<InstanceName>. " +
                    $"Parser errors: {string.Join(", ", errors)}");
            }

            CommandLineOptions options = ((Parsed<CommandLineOptions>)parseResult).Value;
            return options.DataPath;
        }

        /// <summary>
        /// Strongly-typed model for the shim's command-line interface,
        /// parsed by the CommandLineParser library.
        /// </summary>
        private sealed class CommandLineOptions
        {
            /// <summary>
            /// Gets or sets the per-instance DRA data directory supplied via
            /// <c>--DRA_DATA_PATH</c>.
            /// </summary>
            /// <example><c>--DRA_DATA_PATH=C:\DRAData\DRA1</c></example>
            [Option(DataPathEnvVar, Required = false,
                HelpText = "Per-instance DRA data directory. Example: --DRA_DATA_PATH=C:\\DRAData\\DRA1")]
            public string DataPath { get; set; }
        }

        // ── Step 2: pre-create the data directory tree ────────────────────────

        /// <summary>
        /// Ensures the per-instance data directory and its <c>Logs\</c> subdirectory exist,
        /// creating them if necessary.
        /// </summary>
        /// <remarks>
        /// This must be called before <see cref="InjectAppDataDirectory"/> so that
        /// the DRA service never encounters a missing directory on its first write.
        /// <see cref="Directory.CreateDirectory"/> is a no-op when the directory already exists.
        /// </remarks>
        /// <param name="dataPath">Absolute path to the per-instance DRA data directory.</param>
        private static void EnsureDirectories(string dataPath)
        {
            Directory.CreateDirectory(dataPath);
            Directory.CreateDirectory(Path.Combine(dataPath, "Logs"));
        }

        // ── Step 3: inject the path into FileManager before the service runs ──

        /// <summary>
        /// Injects <paramref name="dataPath"/> into <c>FileManager.AppDataDirectory</c>
        /// via reflection before any DRA code reads the property.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <c>FileManager</c> is a singleton whose <c>AppDataDirectory</c> getter lazily
        /// resolves to <c>%ProgramData%\Microsoft\...Document Routing</c> and caches the
        /// result.  Its internal setter writes the same backing field, so calling it before
        /// the getter is ever invoked permanently overrides the machine-wide default for the
        /// lifetime of this process.
        /// </para>
        /// <para>
        /// Steps performed internally:
        /// <list type="number">
        ///   <item><description>Resolve <c>FileManager</c> type from the Runtime assembly.</description></item>
        ///   <item><description>Force singleton creation via <c>FileManager.Instance</c> (triggers double-checked locking).</description></item>
        ///   <item><description>Obtain the non-public <c>set_AppDataDirectory</c> method via <see cref="BindingFlags.NonPublic"/>.</description></item>
        ///   <item><description>Invoke the setter with <paramref name="dataPath"/>.</description></item>
        /// </list>
        /// </para>
        /// </remarks>
        /// <param name="dataPath">Absolute path to the per-instance DRA data directory.</param>
        /// <exception cref="MissingMemberException">
        /// Thrown when the expected <c>Instance</c> property, <c>AppDataDirectory</c> property,
        /// or its setter cannot be found by reflection (indicates a DRA Runtime version mismatch).
        /// </exception>
        /// <exception cref="InvalidOperationException">
        /// Thrown when <c>FileManager.Instance</c> returns <see langword="null"/>.
        /// </exception>
        private static void InjectAppDataDirectory(string dataPath)
        {
            // Resolve FileManager type. Runtime.dll is in the same directory as this
            // shim, so the CLR will find it via normal AppDomain probing.
            Type fileManagerType = Type.GetType(FileManagerTypeName, throwOnError: true);

            // Force the singleton to be created by calling get_Instance().
            // This sets FileManager.instance via double-checked locking.
            PropertyInfo instanceProp = fileManagerType.GetProperty(
                "Instance",
                BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);

            if (instanceProp == null)
                throw new MissingMemberException("FileManager.Instance property not found.");

            object fileManagerInstance = instanceProp.GetValue(null);

            if (fileManagerInstance == null)
                throw new InvalidOperationException("FileManager.Instance returned null.");

            // Call set_AppDataDirectory(dataPath) on the instance.
            // This is an 'internal' (assembly-visibility) property setter --
            // reachable via reflection with NonPublic flag.
            PropertyInfo appDataDirProp = fileManagerType.GetProperty(
                "AppDataDirectory",
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);

            if (appDataDirProp == null)
                throw new MissingMemberException("FileManager.AppDataDirectory property not found.");

            MethodInfo setter = appDataDirProp.GetSetMethod(nonPublic: true);

            if (setter == null)
                throw new MissingMemberException("FileManager.AppDataDirectory setter not found.");

            setter.Invoke(fileManagerInstance, new object[] { dataPath });
        }

        // ── Step 4: run the real service ──────────────────────────────────────

        /// <summary>
        /// Loads the real DRA Windows Service assembly, instantiates its
        /// <see cref="ServiceBase"/> subclass, and hands control to the SCM via
        /// <see cref="ServiceBase.Run(ServiceBase)"/>.
        /// </summary>
        /// <remarks>
        /// The method loads
        /// <c>Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe</c>
        /// from the same directory as this shim using <see cref="Assembly.LoadFrom"/>.
        /// <see cref="ServiceBase.Run(ServiceBase)"/> blocks until the SCM sends a stop command.
        /// </remarks>
        /// <exception cref="FileNotFoundException">
        /// Thrown when <c>Service.exe</c> cannot be found alongside this shim.
        /// </exception>
        /// <exception cref="TypeLoadException">
        /// Thrown when the expected service type cannot be resolved from the loaded assembly.
        /// </exception>
        private static void RunRealService()
        {
            // Load Service.exe as an assembly from the same directory as this shim.
            string shimDir = Path.GetDirectoryName(
                Assembly.GetExecutingAssembly().Location);

            string serviceExePath = Path.Combine(
                shimDir,
                "Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe");

            if (!File.Exists(serviceExePath))
                throw new FileNotFoundException(
                    $"DRA Service.exe not found at: {serviceExePath}");

            Assembly serviceAssembly = Assembly.LoadFrom(serviceExePath);

            Type serviceType = serviceAssembly.GetType(ServiceClassName, throwOnError: true);

            // The Service constructor sets ServiceBase.ServiceName to the embedded resource value:
            //   "Microsoft Dynamics 365 Document Routing Service"
            // ServiceBase.Run() calls StartServiceCtrlDispatcher with that name.
            // The SCM matches by this name, so it must equal the sc.exe registered name.
            // Override it to the per-instance name (e.g. "DRA1") read from DRA_SERVICE_NAME.
            ServiceBase serviceInstance = (ServiceBase)Activator.CreateInstance(serviceType);

            // Hand off to the SCM. This call blocks until the service stops.
            ServiceBase.Run(serviceInstance);
        }

    // ── Error reporting ────────────────────────────────────────────────────

    /// <summary>
    /// Attempts to write a startup-failure event to the Windows Application Event Log.
    /// </summary>
    /// <remarks>
    /// Uses the source name <c>"Docentric.D365FO.DRAServiceShim"</c>, creating it if it does not
    /// already exist.  The event ID is <c>1001</c> with type
    /// <see cref="EventLogEntryType.Error"/>.
    /// All exceptions are silently swallowed; if the Event Log write fails the SCM error
    /// recorded by the re-thrown exception in <see cref="Main"/> is sufficient.
    /// </remarks>
    /// <param name="ex">The exception that caused the service to fail to start.</param>
    private static void WriteEventLogError(Exception ex)
        {
            try
            {
                const string source = "Docentric.D365FO.DRAServiceShim";
                if (!EventLog.SourceExists(source))
                    EventLog.CreateEventSource(source, "Application");

                EventLog.WriteEntry(
                    source,
                    $"Docentric.D365FO.DRAServiceShim failed to start:{Environment.NewLine}{ex}",
                    EventLogEntryType.Error,
                    1001);
            }
            catch
            {
                // Best effort -- if we can't write to event log, the SCM error is enough.
            }
        }
    }
}
