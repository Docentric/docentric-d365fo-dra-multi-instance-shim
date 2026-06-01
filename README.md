# Docentric DRA Multi-Instance Shim

Run multiple **Microsoft Dynamics 365 Document Routing Agent (DRA)** instances on the same Windows server, each writing to its own isolated data directory.

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

1. Open the **Microsoft Dynamics 365 Document Routing Agent** application on the target server.
2. Sign in with your Azure AD / Microsoft account.
3. Configure the AOS URL and any other settings required by your environment.
4. Confirm the agent shows a **Connected** status and can receive print jobs.
5. Close the Agent UI.

At this point the following files exist and are up to date in the reference data directory (`C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing\`):

| File | Purpose |
|---|---|
| `Microsoft.Dynamics.AX.Framework.DocumentRouting.config` | AOS URL, tenant, and agent settings |
| `TokenCache2.dat` | Cached Azure AD authentication token |
| `Microsoft.Dynamics.AX.Framework.DocumentRouting.ExcludedPrintersSet.xml` | Excluded printers list |

The install script automatically copies all three files into each instance's data directory (`<DataRoot>\<Name>\`) so every instance starts with the same credentials and configuration.

### 4. Install instances

```powershell
# Install three instances with default paths
.\Install-DRAInstances.ps1 -InstanceNames "DRA1","DRA2","DRA3"

# Install with custom data and binary roots
.\Install-DRAInstances.ps1 -InstanceNames "DRA1","DRA2" `
    -InstancesRoot "D:\DRAInstances" `
    -DataRoot      "D:\DRAData"
```

Each instance gets:
- **Binaries**: `<InstancesRoot>\<Name>\` — a full copy of the DRA directory with the shim placed alongside `Service.exe`.
- **Data**: `<DataRoot>\<Name>\` — isolated config, token cache, excluded printers, and logs.
- **Service**: an auto-start Windows service named `<Name>` (e.g. `DRA1`).

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

### Re-authenticate or update settings in the base DRA installation

1. Open the **DRA Agent UI**, make your changes, and confirm a **Connected** status.
2. Stop all instances:
   ```powershell
   Get-Service DRA* | Stop-Service
   ```
3. Copy the updated files to each instance data directory:
   ```powershell
   $referenceDataPath = "C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing"
   $dataRoot          = "C:\DRAData"
   $filesToSync = @(
       "Microsoft.Dynamics.AX.Framework.DocumentRouting.config",
       "TokenCache2.dat"
   )

   Get-ChildItem -Directory $dataRoot | ForEach-Object {
       foreach ($file in $filesToSync) {
           $src = Join-Path $referenceDataPath $file
           $dst = Join-Path $_.FullName $file
           if (Test-Path $src) {
               Copy-Item $src $dst -Force
               Write-Host "Copied $file -> $($_.FullName)"
           }
       }
   }
   ```
4. Start the instances again:
   ```powershell
   Get-Service DRA* | Start-Service
   ```

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
| `-ServiceAccount` | `LocalSystem` | Service account (`LocalSystem` or `DOMAIN\user`) |
| `-ServiceAccountPassword` | *(empty)* | Password for domain service accounts |

### `Uninstall-DRAInstances.ps1`

| Parameter | Default | Description |
|---|---|---|
| `-InstanceNames` | *(required)* | Names to remove, or `"ALL"` to remove every `DRA*` service |
| `-InstancesRoot` | `C:\DRAInstances` | Root folder containing per-instance binary directories |
| `-ServicePrefix` | `DRA` | Prefix used when resolving `"ALL"` |
| `-RemoveData` | `$false` | Also delete per-instance data directories |
| `-RemoveBinaries` | `$true` | Delete per-instance binary directories |

---

## ⚠️ Disclaimer

> **This solution is a Proof of Concept (POC).**
>
> It is provided by **Docentric** as-is, without any warranty — express or implied — including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement. Use it at your own risk.
>
> Docentric accepts no liability for any damage, data loss, or service disruption arising from the use of this software. It is not an officially supported product and may break with future updates to the Microsoft Dynamics 365 Document Routing Agent.
>
> Always test in a non-production environment before deploying to production.
