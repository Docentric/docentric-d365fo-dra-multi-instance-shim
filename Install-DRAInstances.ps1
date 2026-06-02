#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs multiple DRA service instances on the same server with fully isolated data directories.

.DESCRIPTION
    PROBLEM
    The DRA Service.exe routes all data (log, config, token cache, excluded printers) through
    FileManager.get_AppDataDirectory(), which calls Environment.GetFolderPath(CommonApplicationData).
    This is a Win32 SHGetFolderPath call that reads a machine-wide registry key.
    It cannot be overridden per-process via environment variables, NSSM, or sc.exe env blocks.

    SOLUTION -- Docentric.D365FO.DRAServiceShim.exe
    A shim executable sits in each per-instance DRA directory and is registered as the service
    binary instead of Service.exe. On startup it:
      1. Reads DRA_DATA_PATH from its own process environment (set via service registry env block --
         this works because it uses GetEnvironmentVariable, not GetFolderPath).
      2. Forces FileManager.Instance singleton creation.
      3. Calls FileManager.set_AppDataDirectory(dataPath) via reflection, pre-populating the
         cached field BEFORE any DRA code reads it.
      4. Loads Service.exe as an assembly and calls ServiceBase.Run() on the real service type.
    Because get_AppDataDirectory() checks IsNullOrWhiteSpace(appDataDirectory) first,
    GetFolderPath is never called once the field is pre-set. All five data paths are isolated.

    Build Docentric.D365FO.DRAServiceShim.exe before running this script:
        cd Docentric.D365FO.DRAServiceShim
        dotnet build -c Release /p:DRALibPath="C:\Program Files (x86)\Microsoft Dynamics 365 for Operations - Document Routing"
    Then copy Docentric.D365FO.DRAServiceShim.exe to the folder specified by -ShimExePath (or the default).

.PARAMETER InstanceNames
    Service instance names to create (e.g. "DRA1", "DRA2", "DRA3").

.PARAMETER DRASourcePath
    Installed DRA binary directory to copy from.
    Default: C:\Program Files (x86)\Microsoft Dynamics 365 for Operations - Document Routing

.PARAMETER ShimExePath
    Path to the compiled Docentric.D365FO.DRAServiceShim.exe.
    Default: <script dir>\Docentric.D365FO.DRAServiceShim.exe

.PARAMETER InstancesRoot
    Root folder for per-instance binary directories.
    Default: C:\DRAInstances

.PARAMETER DataRoot
    Root folder for per-instance data directories.
    Default: C:\DRAData

.PARAMETER ReferenceDataPath
    Configured DRA data directory to copy credentials and settings from.
    Default: C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing

.PARAMETER ServiceAccount
    "LocalSystem" or "DOMAIN\user". Default: LocalSystem.

.PARAMETER ServiceAccountPassword
    Password for domain\user service accounts.

.EXAMPLE
    .\Install-DRAInstances.ps1 -InstanceNames "DRA1","DRA2","DRA3"

.EXAMPLE
    .\Install-DRAInstances.ps1 -InstanceNames "DRA1","DRA2" `
        -DataRoot "D:\DRAData" -InstancesRoot "D:\DRAInstances"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]] $InstanceNames,

    [string] $DRASourcePath = "${env:ProgramFiles(x86)}\Microsoft Dynamics 365 for Operations - Document Routing",

    [string] $ShimExePath = (Join-Path $PSScriptRoot "Docentric.D365FO.DRAServiceShim.exe"),

    [string] $InstancesRoot = "C:\DRAInstances",

    [string] $DataRoot = "C:\DRAData",

    [string] $ReferenceDataPath = "C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing",

    [string] $ServiceAccount = "LocalSystem",

    [string] $ServiceAccountPassword = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$SERVICE_EXE  = "Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe"
$SHIM_EXE     = "Docentric.D365FO.DRAServiceShim.exe"
$ETW_MANIFEST       = "Microsoft.Dynamics.ApplicationPlatform.DocumentRouting.man"
$ETW_MANIFEST_SSRS  = "Microsoft.Dynamics.ApplicationPlatform.SSRSReportRuntime.man"

$REFERENCE_FILES = @(
    "Microsoft.Dynamics.AX.Framework.DocumentRouting.config"
    "TokenCache2.dat"
    "Microsoft.Dynamics.AX.Framework.DocumentRouting.ExcludedPrintersSet.xml"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prints a cyan section-header line to the console, visually separating installation steps.
function Write-Step([string]$Msg) { Write-Host ""; Write-Host "> $Msg" -ForegroundColor Cyan }
# Prints a green [OK] status line to indicate a step completed successfully.
function Write-OK([string]$Msg)   { Write-Host "  [OK]   $Msg" -ForegroundColor Green }
# Prints a yellow [WARN] status line for non-fatal issues that may need attention.
function Write-Warn([string]$Msg) { Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }

<#
.SYNOPSIS
    Verifies the current process is running with Administrator privileges.
.DESCRIPTION
    Checks the current Windows identity against the built-in Administrator role.
    Throws a terminating error if the check fails, preventing the rest of the
    script from running without the required elevation.
#>
function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}

<#
.SYNOPSIS
    Verifies that the DRA Service executable exists at the given source path.
.PARAMETER Path
    The DRA installation directory to check (value of -DRASourcePath).
.DESCRIPTION
    Throws a terminating error if Service.exe is not found, guarding against
    typos or an uninstalled/non-default DRA location.
#>
function Assert-SourceExists([string]$Path) {
    if (-not (Test-Path (Join-Path $Path $SERVICE_EXE))) {
        throw "DRA Service.exe not found at: $Path`nCheck -DRASourcePath."
    }
}

<#
.SYNOPSIS
    Verifies that the compiled DRAServiceShim executable exists at the given path.
.PARAMETER Path
    Full path to Docentric.D365FO.DRAServiceShim.exe (value of -ShimExePath).
.DESCRIPTION
    Throws a terminating error with build instructions if the shim is missing,
    reminding the caller to compile the Docentric.D365FO.DRAServiceShim project before running this script.
#>
function Assert-ShimExists([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Docentric.D365FO.DRAServiceShim.exe not found at: $Path`n" +
              "Build it first:`n" +
              "  cd Docentric.D365FO.DRAServiceShim`n" +
              "  dotnet build -c Release /p:DRALibPath=`"$DRASourcePath`""
    }
}

<#
.SYNOPSIS
    Verifies that a valid reference DRA config file exists at the given data path.
.PARAMETER Path
    Path to the reference DRA data directory (value of -ReferenceDataPath).
.DESCRIPTION
    Checks for the presence of the main DRA config file, which is only created
    after the base DRA installation has been authenticated via the Agent UI.
    Throws a terminating error with remediation guidance if the file is absent.
#>
function Assert-ReferenceData([string]$Path) {
    $cfg = Join-Path $Path "Microsoft.Dynamics.AX.Framework.DocumentRouting.config"
    if (-not (Test-Path $cfg)) {
        throw "Reference config not found: $cfg`nAuthenticate the base DRA install via the Agent UI first."
    }
}

<#
.SYNOPSIS
    Registers the DRA ETW (Event Tracing for Windows) manifest with wevtutil.
.PARAMETER SourcePath
    The DRA installation directory containing the .man manifest file.
.DESCRIPTION
    Unregisters any existing manifest first (to handle re-installs cleanly),
    then registers it so DRA event channels are available in the Windows
    Event Log. Emits a warning instead of failing if the manifest file is
    absent or wevtutil reports a non-zero exit code.
#>
function Register-EtwManifest([string]$SourcePath) {
    Write-Step "Registering ETW manifests"
    foreach ($manifest in @($ETW_MANIFEST, $ETW_MANIFEST_SSRS)) {
        $manFile = Join-Path $SourcePath $manifest
        if (-not (Test-Path $manFile)) {
            Write-Warn "ETW manifest not found: $manFile -- skipping"
            continue
        }
        # Unregister first to handle re-installs cleanly
        & wevtutil um $manFile 2>&1 | Out-Null
        & wevtutil im $manFile 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "wevtutil im returned $LASTEXITCODE for $manifest -- channels may already be registered"
        } else {
            Write-OK "ETW channels registered: $manifest"
        }
    }
}

<#
.SYNOPSIS
    Creates a per-instance binary directory by copying DRA files and placing the shim.
.PARAMETER SourcePath
    The DRA source installation directory to copy binaries from.
.PARAMETER DestPath
    The destination directory for this instance's binaries.
    If it already exists it is deleted and recreated.
.PARAMETER ShimSrc
    Full path to the compiled Docentric.D365FO.DRAServiceShim.exe to deploy
    alongside the DRA binaries.
.DESCRIPTION
    Copies all files from SourcePath to DestPath recursively. SQLite transient
    files (*.db, *.db-shm, *.db-wal) and any file locked by another process are
    skipped with a warning rather than aborting the copy. After the copy,
    DRAServiceShim.exe is placed in the root of DestPath so the Windows service
    can reference it as the service binary.
#>
function New-InstanceBinDirectory([string]$SourcePath, [string]$DestPath, [string]$ShimSrc) {
    Write-Step "Copying binaries to: $DestPath"

    if (Test-Path $DestPath) {
        Write-Warn "Directory exists, removing and recreating"
        Remove-Item $DestPath -Recurse -Force
    }

    # Copy file-by-file so locked transient files (SQLite WAL lock files created
    # by VS/indexers: *.db-shm, *.db-wal, *.db) are skipped instead of aborting.
    $SKIP_EXTENSIONS = @('.db-shm', '.db-wal', '.db')

    New-Item -Path $DestPath -ItemType Directory -Force | Out-Null

    Get-ChildItem -Path $SourcePath -Recurse | ForEach-Object {
        $relativePath = $_.FullName.Substring($SourcePath.TrimEnd('\').Length + 1)
        $destItem     = Join-Path $DestPath $relativePath

        if ($_.PSIsContainer) {
            New-Item -Path $destItem -ItemType Directory -Force | Out-Null
            return
        }

        if ($SKIP_EXTENSIONS -contains $_.Extension.ToLower()) {
            Write-Warn "Skipping locked/transient file: $($_.Name)"
            return
        }

        try {
            Copy-Item -Path $_.FullName -Destination $destItem -Force
        }
        catch [System.IO.IOException] {
            Write-Warn "Skipping locked file: $($_.Name) -- $_"
        }
    }

    Write-OK "DRA binaries copied"

    # Place Docentric.D365FO.DRAServiceShim.exe alongside Service.exe
    Copy-Item -Path $ShimSrc -Destination (Join-Path $DestPath $SHIM_EXE) -Force
    Write-OK "Docentric.D365FO.DRAServiceShim.exe placed"
}

<#
.SYNOPSIS
    Creates a per-instance data directory and seeds it from the reference installation.
.PARAMETER DataPath
    The target data directory for this instance (e.g. C:\DRAData\DRA1).
.PARAMETER ReferencePath
    The reference DRA data directory to copy credentials and settings from.
.DESCRIPTION
    Creates the Logs sub-directory, then copies the three reference files
    (DRA config, token cache, excluded printers list) from ReferencePath into
    DataPath. Missing reference files are skipped with a warning so that
    partially-configured environments do not block installation.
#>
function New-InstanceDataDirectory([string]$DataPath, [string]$ReferencePath) {
    Write-Step "Creating data directory: $DataPath"

    New-Item -Path (Join-Path $DataPath "Logs") -ItemType Directory -Force | Out-Null
    Write-OK "Directory structure created"

    foreach ($file in $REFERENCE_FILES) {
        $src = Join-Path $ReferencePath $file
        $dst = Join-Path $DataPath $file
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $dst -Force
            Write-OK "Copied: $file"
        } else {
            Write-Warn "Not in reference, skipping: $file"
        }
    }
}

<#
.SYNOPSIS
    Registers a Windows service for a single DRA instance using sc.exe.
.PARAMETER ServiceName
    The SCM service name (e.g. "DRA1"). Also used as the display-name suffix.
.PARAMETER ShimExe
    Full path to Docentric.D365FO.DRAServiceShim.exe inside the instance bin
    directory. Registered as the service binary path.
.PARAMETER DataPath
    Per-instance data directory passed to the shim via --DRA_DATA_PATH so the
    DRA process writes logs, config, and cache to the isolated location.
.PARAMETER Account
    Windows account under which the service runs. Use "LocalSystem" (default)
    or a "DOMAIN\user" account.
.PARAMETER Password
    Password for the service account. Ignored when Account is LocalSystem.
.DESCRIPTION
    Stops and removes any pre-existing service with the same name, then
    creates a new auto-start service whose binPath includes
    --DRA_DATA_PATH="<DataPath>" so the shim receives the data path as a
    command-line argument (primary path). The data path is also written to the
    service's registry Environment block (HKLM:\...\Services\<Name>\Environment)
    as a fallback matching the ReadDataPath() fallback chain in Program.cs.
    Configures failure recovery to restart the service up to three times.
#>
function Install-ServiceWithSc {
    param(
        [string]$ServiceName,
        [string]$ShimExe,
        [string]$DataPath,
        [string]$Account,
        [string]$Password
    )

    Write-Step "Registering service: $ServiceName"

    # Remove existing service
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warn "Service '$ServiceName' exists -- stopping and removing"
        if ($existing.Status -eq "Running") {
            Stop-Service -Name $ServiceName -Force
            $waited = 0
            while ((Get-Service -Name $ServiceName).Status -eq "Running" -and $waited -lt 15) {
                Start-Sleep -Seconds 1; $waited++
            }
        }
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }

    $displayName = "Microsoft Dynamics 365 Document Routing Service $ServiceName"

    # Pass --DRA_DATA_PATH as a command-line argument to the shim.
    # Program.cs reads it via CommandLineOptions (TryReadDataPathFromArgs) before
    # falling back to the environment variable, so this is the primary source.
    $exeQuoted   = "`"$ShimExe`" --DRA_DATA_PATH=`"$DataPath`""

    if ($Account -eq "LocalSystem" -or [string]::IsNullOrWhiteSpace($Account)) {
        sc.exe create $ServiceName binPath= $exeQuoted start= auto DisplayName= $displayName | Out-Null
    } else {
        sc.exe create $ServiceName binPath= $exeQuoted start= auto DisplayName= $displayName `
            obj= $Account password= $Password | Out-Null
    }

    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        throw "Failed to create service '$ServiceName'."
    }

    $serviceDescription = "Document routing service for Microsoft Dynamics 365 for Finance and Operations (instance name: $ServiceName, Docentric.D365FO.DRAServiceShim)"
    sc.exe description $ServiceName $serviceDescription | Out-Null
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

    # Also keep the registry environment block as a fallback, matching the
    # ReadDataPath() fallback chain in Program.cs (args -> env var).
    Write-Step "Setting DRA_DATA_PATH environment for service (fallback)"
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Environment"
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name "DRA_DATA_PATH" -Value $DataPath
    Write-OK "DRA_DATA_PATH = $DataPath"

    Write-OK "Service registered: $ServiceName"
}

<#
.SYNOPSIS
    Prints a post-installation summary table of all created DRA instances.
.PARAMETER Instances
    A list of hashtables, each containing ServiceName, BinPath, and DataPath
    keys for one installed instance.
.DESCRIPTION
    Outputs a formatted console report showing the service name, binary
    directory, and data directory for every instance, followed by quick-start
    commands for starting all services and verifying isolated log output.
#>
function Show-Summary([System.Collections.Generic.List[hashtable]]$Instances) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor White
    Write-Host "  Installation complete -- $($Instances.Count) instance(s)" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor White
    foreach ($inst in $Instances) {
        Write-Host ""
        Write-Host "  Service  : $($inst.ServiceName)" -ForegroundColor Yellow
        Write-Host "  Binaries : $($inst.BinPath)"
        Write-Host "  Data dir : $($inst.DataPath)"
    }
    Write-Host ""
    Write-Host "  Start all instances:" -ForegroundColor Gray
    Write-Host "    Get-Service DRA* | Start-Service" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Verify isolated log files:" -ForegroundColor Gray
    Write-Host "    Get-ChildItem $DataRoot -Filter *.log -Recurse" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  If TokenCache2.dat was not copied, authenticate each instance" -ForegroundColor Gray
    Write-Host "  via the DRA Agent UI or copy a valid cache file into each data directory." -ForegroundColor Gray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Assert-Admin
Assert-SourceExists $DRASourcePath
Assert-ShimExists $ShimExePath
Assert-ReferenceData $ReferenceDataPath

Register-EtwManifest -SourcePath $DRASourcePath

$results = [System.Collections.Generic.List[hashtable]]::new()

foreach ($name in $InstanceNames) {
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Magenta
    Write-Host "  Instance: $name" -ForegroundColor Magenta
    Write-Host "===================================================" -ForegroundColor Magenta

    $instanceBinPath  = Join-Path $InstancesRoot $name
    $instanceDataPath = Join-Path $DataRoot $name
    $shimExeInst      = Join-Path $instanceBinPath $SHIM_EXE

    New-InstanceBinDirectory `
        -SourcePath $DRASourcePath `
        -DestPath   $instanceBinPath `
        -ShimSrc    $ShimExePath

    New-InstanceDataDirectory `
        -DataPath      $instanceDataPath `
        -ReferencePath $ReferenceDataPath

    Install-ServiceWithSc `
        -ServiceName $name `
        -ShimExe     $shimExeInst `
        -DataPath    $instanceDataPath `
        -Account     $ServiceAccount `
        -Password    $ServiceAccountPassword

    $results.Add(@{
        ServiceName = $name
        BinPath     = $instanceBinPath
        DataPath    = $instanceDataPath
    })
}

Show-Summary -Instances $results
