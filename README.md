# Docentric D365FO DRA Multi-Instance Shim

Run multiple **Microsoft Dynamics 365 Document Routing Agent (DRA)** instances on the same Windows server, each writing to its own isolated data directory.

Running multiple DRA instances is a known technique to reduce printing delays and increase throughput in high-volume D365FO printing scenarios — for example, when many documents are queued for different network printers. Because DRA polls for new print jobs every 5 seconds by default and processes only one document per poll, parallelising across several instances significantly cuts end-to-end latency. For background on DRA internals and the case for multiple instances, see [Reduce the Delay When Printing via Document Routing Agent](https://ax.docentric.com/reduce-the-delay-when-printing-via-document-routing-agent/).

However, simply running `Service.exe` multiple times hits a hard wall: all instances share the same data folder, causing file-locking collisions on log files. This shim solves that problem.

---

## The Problem

All DRA instances on a single machine share the same data folder:

```
C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing\
```

When two or more instances run simultaneously they collide on the same log file, causing `IOException` file-locking errors. The root cause is that `FileManager.AppDataDirectory` calls `Environment.GetFolderPath(CommonApplicationData)` — a machine-wide Win32 API that **cannot** be overridden per-process through environment variables, NSSM, or `sc.exe`.

## The Solution

`Docentric.D365FO.DRAServiceShim.exe` is a thin wrapper that:

1. Reads a per-instance data path from the `--DRA_DATA_PATH` command-line argument (or the `DRA_DATA_PATH` environment variable as a fallback).
2. Injects that path into `FileManager.AppDataDirectory` via reflection **before** the real service starts, so the machine-wide default is never used.
3. Loads and runs the real `Service.exe` as a managed assembly.

Each instance gets its own `Logs\`, config, token cache, and excluded-printers file.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Windows Server / Windows 10+ | x86, 64-bit OS with WOW64 |
| .NET Framework 4.8 | Must be installed on the target server |
| .NET SDK 8+ | Required on the **build machine** only (`dotnet build`) |
| DRA installed | The base DRA installation must exist and have been authenticated via the Agent UI at least once |
| PowerShell 5.1+ | All scripts use `#Requires -RunAsAdministrator` |
| Administrator rights | Required for both build output copy and service registration |
| Service account | The Windows account used to authenticate DRA in the Agent UI; must be a domain or local user (not `LocalSystem`) so the token cache is accessible and the Azure AD token can be silently refreshed |

---

## Repository Layout

```
\
├── Docentric.D365FO.DRAServiceShim\   # C# shim source (.NET Framework 4.8, x86)
│   └── Program.cs
├── dist\                              # Build output (created by Build.ps1)
│   └── Docentric.D365FO.DRAServiceShim.exe
├── Build.ps1                          # Builds the shim and copies output
├── Install-DRAInstances.ps1           # Creates and registers DRA service instances
├── Uninstall-DRAInstances.ps1         # Stops and removes DRA service instances
├── Update-DRAInstancesConfig.ps1      # Propagates updated config/token files to all instances
└── README.md
```

---

## Getting Started

### 1. Clone the repository

Clone this repository to your local machine and navigate into it:

```powershell
git clone https://github.com/Docentric/<repo-name>.git
cd <repo-name>
```

Then copy the contents of this folder to your target server where you have DRA installed and want to run multiple instances.

### 2. Build the shim

Run from an **elevated PowerShell** prompt. Adjust `-DRASourcePath` if your DRA installation is in a non-default location.

```powershell
.\Build.ps1
# or, if DRA is installed elsewhere:
.\Build.ps1 -DRASourcePath "D:\CustomDRAPath"
```

The compiled `Docentric.D365FO.DRAServiceShim.exe` is written to the `dist\` folder and copied next to the install script automatically.

### 3. Authenticate and configure DRA before installing instances

> **This step is mandatory.** The install script seeds credentials and settings from the base DRA installation into each instance. If this is skipped the instances will not be able to connect to Dynamics 365.

1. Sign in to Windows as the dedicated service account (e.g. `DOMAIN\draserviceuser`) that will later run the DRA services.
2. Open the **Microsoft Dynamics 365 Document Routing Agent** application on the target server.
3. Sign in with your Azure AD / Microsoft account.
4. Configure the AOS URL and any other settings required by your environment.
5. Confirm the agent shows a **Connected** status and can receive print jobs.
6. Close the Agent UI.

> **Important:** Note the Windows account you are currently signed in as when you perform this step. You must install the services under the **same account** so they can read and refresh `TokenCache2.dat`. Using `LocalSystem` or a different account will cause silent token-refresh failures once the cached token expires.

At this point

| File | Purpose |
|---|---|
| `Microsoft.Dynamics.AX.Framework.DocumentRouting.config` | AOS URL, tenant, and agent settings |
| `TokenCache2.dat` | Cached Azure AD authentication token |
| `Microsoft.Dynamics.AX.Framework.DocumentRouting.ExcludedPrintersSet.xml` | Excluded printers list |

The install script automatically copies all three files into each instance's data directory (`<DataRoot>\<Name>\`) so every instance starts with the same credentials and configuration.

### 4. Install instances

Before installing, ensure the service account has **Log on as a service** rights. You can grant them via __Local Security Policy > Security Settings > Local Policies > User Rights Assignment > Log on as a service__, or with the following PowerShell snippet (run once on the target server, elevated):

```powershell
$account = "DOMAIN\draserviceuser"
secedit /export /cfg "$env:TEMP\secpol.cfg" | Out-Null
(Get-Content "$env:TEMP\secpol.cfg") -replace "(SeServiceLogonRight\s*=.*)", "`$1,$account" |
    Set-Content "$env:TEMP\secpol.cfg"
secedit /import /cfg "$env:TEMP\secpol.cfg" /db secedit.sdb | Out-Null
secedit /configure /db secedit.sdb | Out-Null
```

```powershell
# Install three instances running as the authenticated user
.\Install-DRAInstances.ps1 -InstanceNames "DRA1","DRA2","DRA3" `
    -ServiceAccount         "DOMAIN\draserviceuser" `
    -ServiceAccountPassword "P@ssword1"

# Install with custom data and binary roots
.\Install-DRAInstances.ps1 -InstanceNames "DRA1","DRA2" `
    -InstancesRoot          "D:\DRAInstances" `
    -DataRoot               "D:\DRAData" `
    -ServiceAccount         "DOMAIN\draserviceuser" `
    -ServiceAccountPassword "P@ssword1"
```

Each instance gets:
- **Binaries**: `<InstancesRoot>\<Name>\` — a full copy of the DRA directory with the shim placed alongside `Service.exe`.
- **Data**: `<DataRoot>\<Name>\` — isolated config, token cache, excluded printers, and logs.
- **Service**: an auto-start Windows service named `<Name>` (e.g. `DRA1`), running as the specified service account.

### 5. Start the services

```powershell
Get-Service DRA* | Start-Service
```

### 6. Verify isolated logging

```powershell
Get-ChildItem C:\DRAData -Filter *.log -Recurse
```

Each instance should have its own log file under `C:\DRAData\<Name>\Logs\`.

---

## Keeping Credentials in Sync

Whenever you re-authenticate or change settings in the DRA Agent UI, the reference files are updated in the base data directory. These changes are **not** automatically propagated to the running instances. You must sync them manually:

> **Token refresh:** When the service runs as the authenticated user, DRA can silently refresh the Azure AD token without manual intervention. If you ever change the service account, you must re-authenticate in the Agent UI **as that new account** and re-copy `TokenCache2.dat` to each instance data directory.

### Re-authenticate or update settings in the base DRA installation

1. Sign in to Windows as the service account, open the **DRA Agent UI**, make your changes, and confirm a **Connected** status.
2. Run `Update-DRAInstancesConfig.ps1` to propagate the updated files to every instance — and optionally restart the services in one step:
   ```powershell
   # Propagate changes and restart all DRA* services automatically
   .\Update-DRAInstancesConfig.ps1 -RestartServices

   # Propagate to specific instances only
   .\Update-DRAInstancesConfig.ps1 -InstanceNames "DRA1","DRA2","DRA3" -RestartServices

   # Propagate without restarting (restart manually afterwards)
   .\Update-DRAInstancesConfig.ps1
   Get-Service DRA* | Start-Service
   ```

The script copies `Microsoft.Dynamics.AX.Framework.DocumentRouting.config`, `TokenCache2.dat`, and `Microsoft.Dynamics.AX.Framework.DocumentRouting.ExcludedPrintersSet.xml` from the reference data directory into each instance data directory. When `-RestartServices` is specified it stops each service, copies the files, then starts the service again.

---

## Uninstalling

```powershell
# Remove specific instances (preserves data directories by default)
.\Uninstall-DRAInstances.ps1 -InstanceNames "DRA1","DRA2"

# Remove all DRA* services and delete everything
.\Uninstall-DRAInstances.ps1 -InstanceNames "ALL" -RemoveData

# Remove services only, keep binaries and data
.\Uninstall-DRAInstances.ps1 -InstanceNames "DRA1","DRA2" -RemoveBinaries:$false
```

`-RemoveData` requires typing `YES` at an interactive confirmation prompt because data deletion is irreversible.

---

## Key Parameters

### `Install-DRAInstances.ps1`

| Parameter | Default | Description |
|---|---|---|
| `-InstanceNames` | *(required)* | Service names to create, e.g. `"DRA1","DRA2"` |
| `-DRASourcePath` | `%ProgramFiles(x86)%\Microsoft Dynamics 365...` | DRA installation directory to copy binaries from |
| `-ShimExePath` | `<script dir>\Docentric.D365FO.DRAServiceShim.exe` | Path to the compiled shim executable |
| `-InstancesRoot` | `C:\DRAInstances` | Root folder for per-instance binary directories |
| `-DataRoot` | `C:\DRAData` | Root folder for per-instance data directories |
| `-ReferenceDataPath` | `C:\ProgramData\Microsoft\Microsoft Dynamics 365...` | Authenticated DRA data directory to seed credentials from |
| `-ServiceAccount` | *(required)* | Domain or local account that performed DRA authentication, e.g. `DOMAIN\draserviceuser`. **Do not use `LocalSystem`** — the token cache is user-scoped and will not be refreshable by a system account |
| `-ServiceAccountPassword` | *(required)* | Password for the service account |

### `Uninstall-DRAInstances.ps1`

| Parameter | Default | Description |
|---|---|---|
| `-InstanceNames` | *(required)* | Names to remove, or `"ALL"` to remove every `DRA*` service |
| `-InstancesRoot` | `C:\DRAInstances` | Root folder containing per-instance binary directories |
| `-ServicePrefix` | `DRA` | Prefix used when resolving `"ALL"` |
| `-RemoveData` | `$false` | Also delete per-instance data directories |
| `-RemoveBinaries` | `$true` | Delete per-instance binary directories |

### `Update-DRAInstancesConfig.ps1`

| Parameter | Default | Description |
|---|---|---|
| `-InstanceNames` | *(auto-discover)* | Service instance names to update, e.g. `"DRA1","DRA2"`. If omitted, all services matching `-ServiceNamePattern` are targeted |
| `-DataRoot` | `C:\DRAData` | Root folder containing per-instance data directories |
| `-ReferenceDataPath` | `C:\ProgramData\Microsoft\Microsoft Dynamics 365...` | Authenticated DRA data directory to copy credentials and settings from |
| `-ServiceNamePattern` | `DRA*` | Wildcard pattern used to discover services when `-InstanceNames` is not supplied |
| `-RestartServices` | `$false` | Stop each service before copying files and start it again afterwards |

---

## ❓ FAQ

### Build is not working — what should I check?

**1. Verify prerequisites are installed**

| Prerequisite | How to check |
|---|---|
| .NET SDK 8+ | `dotnet --version` — must be `8.x` or higher |
| .NET Framework 4.8 | Check *Control Panel > Programs > Turn Windows features on or off* or `Get-WindowsOptionalFeature -Online -FeatureName NetFx4` |
| DRA installed | Confirm `Service.exe` exists in `-DRASourcePath` (default: `%ProgramFiles(x86)%\Microsoft Dynamics 365 for Operations - Document Routing`) |

**2. Common build failures**

| Symptom | Likely cause | Fix |
|---|---|---|
| `DRA source path not found` | `-DRASourcePath` points to a non-existent directory | Pass the correct path: `.\Build.ps1 -DRASourcePath "D:\DRA"` |
| `Build failed` (MSBuild errors about missing `Runtime.dll` / `Service.exe`) | `DRALibPath` MSBuild property does not point to the DRA binaries | Ensure `-DRASourcePath` is the actual DRA installation folder containing those files |
| `Build output not found in: dist\` | The `dist\` folder was not created or the project's post-build copy step failed | Check the MSBuild output for errors; confirm the `.csproj` has an `AfterBuild` target that copies output to `dist\` |
| `dotnet: command not found` | .NET SDK not on `PATH` | Install .NET SDK 8+ and restart the PowerShell session |

---

### Installation fails — what should I check?

**Common `Install-DRAInstances.ps1` failures**

| Symptom | Likely cause | Fix |
|---|---|---|
| `Run this script as Administrator` | Script not elevated | Right-click PowerShell → *Run as Administrator* |
| `DRA Service.exe not found at: <path>` | DRA not installed or `-DRASourcePath` is wrong | Install DRA first, or pass the correct path |
| `Docentric.D365FO.DRAServiceShim.exe not found` | `Build.ps1` was not run, or the shim was not copied next to the install script | Run `.\Build.ps1` first; the shim is copied automatically |
| `Reference config not found` | The base DRA installation was never authenticated via the Agent UI | Open DRA Desktop, sign in, and confirm *Connected* status before running the install script |
| `Failed to create service '<Name>'` | `sc.exe` failed — often a permission issue or a leftover service in a broken state | Open *Services*, find the service, stop and delete it manually, then re-run |
| Service account `Log on as a service` right missing | The domain account has not been granted the right | See the `secedit` snippet in *Step 4* of Getting Started |

---

### Services start but DRA cannot authenticate — what should I check?

This is the most common post-install problem. The symptoms in the Windows Event Log are:

- **Operational log**: `Microsoft.Identity.Client.MsalUiRequiredException` — `ErrorCode: user_null` — *No account or login hint was passed to the AcquireTokenSilent call.*
- **Admin log**: repeated *Document Routing MSAL authenticate start / stop* pairs that never result in a successful sign-in.
- **Follow-on errors**: `AggregateException` → `MsalException` — *Could not get authentication result* — in `DocumentRoutingTimer_Tick`, `ServiceWorker.SignIn()`, and `PollingDocument()`.
- **Upload failures**: `UploadDRAInformationAsync` cannot set the OData authorization header for the same reason.
- **Secondary**: `EventLogNotFoundException` — *The specified channel could not be found* — in `GetActiveGlobalChannels`. This is not the authentication blocker but indicates the ETW manifest was not registered; re-running `Install-DRAInstances.ps1` or registering the manifest manually with `wevtutil im` will resolve it.

**Root cause**

DRA uses MSAL silent token acquisition. The token cache (`TokenCache2.dat`) is **user-scoped**: it is only readable by the Windows account that performed the original sign-in via the Agent UI. If the service runs as a different account (e.g. `LocalSystem` — security context `S-1-5-18`) MSAL cannot find a cached account and throws `user_null`.

**How to fix**

1. Open **Windows Services** (`services.msc`).
2. Find each `DRA*` service → *Properties* → **Log On** tab.
3. Confirm *This account* is set to the **same domain/local user** that signed in through the DRA Agent UI (e.g. `DOMAIN\draserviceuser`). If it shows *Local System*, that is the problem.
4. If the account is wrong — or if you are unsure — re-run the install script with the correct `-ServiceAccount` and `-ServiceAccountPassword` parameters.
5. Sign in interactively to Windows as that same account, open the **DRA Agent UI**, sign in, and confirm a **Connected** status. This refreshes `TokenCache2.dat`.
6. Copy the updated `TokenCache2.dat` to each instance data directory (see *Keeping Credentials in Sync*).
7. Restart the services:
   ```powershell
   Get-Service DRA* | Restart-Service
   ```
8. Recheck the Operational log — authentication errors should be gone.

> **Note:** `LocalSystem` cannot silently refresh Azure AD tokens because it has no user identity. Always run DRA services under a named domain or local user account.

### An assembly cannot be loaded — what should I check?

If the shim crashes on startup with an error such as:

```
System.IO.FileLoadException: Could not load file or assembly 'Newtonsoft.Json, Version=…' or one of its dependencies.
```

or

```
System.IO.FileNotFoundException: Could not load file or assembly 'Microsoft.Identity.Client, …'
```

the most likely cause is that `Docentric.D365FO.DRAServiceShim.exe.config` is missing binding redirects that the real DRA service relies on.

**Why this happens**

When the shim loads `Service.exe` as a managed assembly, the CLR resolves all dependent assemblies in the context of the **shim's** AppDomain. The binding redirects in `Service.exe.config` are **not** automatically inherited — only the redirects in `Docentric.D365FO.DRAServiceShim.exe.config` apply.

**How to fix**

Make sure `Docentric.D365FO.DRAServiceShim.exe.config` contains the same `<assemblyBinding>` entries as `Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe.config`. The reference config that ships with this repository already includes all known redirects. If you see a new assembly load failure after a DRA update, open both config files side-by-side and copy any missing `<dependentAssembly>` blocks into the shim config.

The full set of binding redirects the shim config must contain:

| Assembly | Redirect to version |
|---|---|
| `Newtonsoft.Json` | `13.0.0.0` |
| `System.Net.Http.Formatting` | `5.2.9.0` |
| `Microsoft.Identity.Client` | `4.70.0.0` |
| `Microsoft.IdentityModel.Abstractions` | `8.3.0.0` |
| `System.Buffers` | `4.0.3.0` |
| `System.Diagnostics.DiagnosticSource` | `8.0.0.1` |
| `System.Memory` | `4.0.1.2` |
| `System.Runtime.CompilerServices.Unsafe` | `6.0.0.0` |
| `Microsoft.Owin` | `4.2.2.0` |
| `Microsoft.Cloud.InstrumentationFramework.Events` | `3.3.9.1` |
| `System.Reflection.Metadata` | `1.4.2.0` |
| `System.ValueTuple` | `4.0.3.0` |
| `System.Collections.Immutable` | `1.2.2.0` |
| `Bond.Attributes` | `9.0.3.100` |
| `Microsoft.Cloud.InstrumentationFramework.Metrics` | `3.3.9.1` |
| `Microsoft.Owin.Security` | `4.2.2.0` |
| `Microsoft.Data.OData` | `5.8.4.0` |
| `Microsoft.Data.Edm` | `5.8.4.0` |
| `Microsoft.Data.Services.Client` | `5.8.4.0` |

> **After a DRA update**, compare `Docentric.D365FO.DRAServiceShim.exe.config` with the freshly installed `Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe.config` and sync any new or changed redirects into the shim config. Then rebuild and redeploy with `.\Build.ps1`.

---

## ⚠️ Disclaimer

> **This solution is a Proof of Concept (POC).**
>
> It is provided by **Docentric** as-is, without any warranty — express or implied — including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement. Use it at your own risk.
>
> Docentric accepts no liability for any damage, data loss, or service disruption arising from the use of this software. It is not an officially supported product and may break with future updates to the Microsoft Dynamics 365 Document Routing Agent.
>
> Always test in a non-production environment before deploying to production.
