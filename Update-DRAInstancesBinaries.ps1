#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Updates the binaries of existing DRA service instances in-place.

.DESCRIPTION
    After upgrading the base DRA installation (e.g. via Windows Update or a
    manual re-install) or after rebuilding Docentric.D365FO.DRAServiceShim.exe,
    run this script to propagate the updated binaries to every per-instance
    binary directory without touching service registration or per-instance data
    directories (config, token cache, excluded printers, logs).

    This script is intentionally non-destructive: it overwrites files in the
    existing instance binary directories rather than deleting and recreating
    them. Service registrations created by Install-DRAInstances.ps1 are
    therefore preserved.

    For each resolved instance the script performs the following steps in order:

      1. STOP   -- If the instance service is currently running it is stopped
                   and the script waits up to 30 seconds for the Stopped state.
                   Whether the service was running is remembered so it can be
                   conditionally restarted after the update.

      2. UPDATE -- All files from DRASourcePath are copied into the instance
                   binary directory, overwriting existing files. SQLite
                   transient files (*.db, *.db-shm, *.db-wal) and any file
                   that is locked by another process are skipped with a warning
                   so that a single inaccessible file does not abort the entire
                   update.

      3. SHIM   -- Docentric.D365FO.DRAServiceShim.exe is overwritten with the
                   freshly compiled shim from ShimExePath. This must be done
                   after the DRA binary copy so the shim is not accidentally
                   overwritten by an older version present in DRASourcePath.

      4. CONFIG -- Docentric.D365FO.DRAServiceShim.exe.config is overwritten
                   with a verbatim copy of
                   Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe.config
                   (just copied into the instance bin dir in step 2).
                   The CLR resolves assembly binding redirects from the
                   entry-point executable's own config file. Because the shim
                   loads Service.exe as a managed assembly, the redirects in
                   Service.exe.config are not inherited -- only those declared
                   in Docentric.D365FO.DRAServiceShim.exe.config apply.
                   Keeping the two files identical guarantees the shim's
                   AppDomain sees the same redirects as the real service.

      5. START  -- The instance service is started again only if it was running
                   before step 1. Services that were already stopped are left
                   stopped so that a deliberately disabled service is not
                   accidentally re-enabled.

.PARAMETER InstanceNames
    One or more service instance names to update (e.g. "DRA1", "DRA2", "DRA3").
    Each name is used both as the Windows service name and as the subdirectory
    name under InstancesRoot that holds the instance binaries.
    If this parameter is omitted, the script auto-discovers all services whose
    names match ServiceNamePattern via the Service Control Manager.

.PARAMETER DRASourcePath
    Full path to the installed DRA binary directory. All files from this
    directory are copied into each instance binary directory during the update.
    Default: %ProgramFiles(x86)%\Microsoft Dynamics 365 for Operations - Document Routing

.PARAMETER ShimExePath
    Full path to the compiled Docentric.D365FO.DRAServiceShim.exe that should
    replace the shim in each instance binary directory.
    Build the shim before running this script:
        cd Docentric.D365FO.DRAServiceShim
        dotnet build -c Release /p:DRALibPath="<DRASourcePath>"
    Default: <script directory>\Docentric.D365FO.DRAServiceShim.exe

.PARAMETER InstancesRoot
    Root folder that contains the per-instance binary directories. Each instance
    is expected to have its binaries under <InstancesRoot>\<InstanceName>\.
    Default: C:\DRAInstances

.PARAMETER ServiceNamePattern
    Wildcard pattern passed to Get-Service to auto-discover instance services
    when InstanceNames is not supplied. Change this if your services use a
    naming convention other than the default "DRA" prefix.
    Default: DRA*

.EXAMPLE
    .\Update-DRAInstancesBinaries.ps1

    Updates all services matching "DRA*". Each service is stopped before the
    binary copy and restarted afterwards only if it was running before.

.EXAMPLE
    .\Update-DRAInstancesBinaries.ps1 -InstanceNames "DRA1","DRA2","DRA3"

    Updates only the three named instances, regardless of what other DRA*
    services may exist on the machine.

.EXAMPLE
    .\Update-DRAInstancesBinaries.ps1 -InstanceNames "DRA1" `
        -DRASourcePath "D:\CustomDRA" `
        -ShimExePath   "D:\build\Docentric.D365FO.DRAServiceShim.exe"

    Updates a single instance from non-default source and shim paths.

.NOTES
    Related scripts in this repository:
      Install-DRAInstances.ps1        -- Creates and registers instances for the first time.
      Uninstall-DRAInstances.ps1      -- Stops and removes instances.
      Update-DRAInstancesConfig.ps1   -- Propagates updated config and token cache files
                                         (data directory files only; does not touch binaries).

    Run order after a DRA upgrade:
      1. Let Windows / the installer update the base DRA binaries in DRASourcePath.
      2. Rebuild Docentric.D365FO.DRAServiceShim.exe if the DRA assemblies changed.
      3. Run this script to push the updated binaries to all instances.
      4. If you also re-authenticated via the DRA Agent UI, run
         Update-DRAInstancesConfig.ps1 to propagate the new token cache and config.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $InstanceNames,

    [string] $DRASourcePath = "${env:ProgramFiles(x86)}\Microsoft Dynamics 365 for Operations - Document Routing",

    [string] $ShimExePath = (Join-Path $PSScriptRoot "Docentric.D365FO.DRAServiceShim.exe"),

    [string] $InstancesRoot = "C:\DRAInstances",

    [string] $ServiceNamePattern = "DRA*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# File name of the real DRA Windows Service executable, used to verify that
# DRASourcePath points to a valid DRA installation.
$SERVICE_EXE = "Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe"

# File name of the shim executable that is registered as the service binary
# for each instance and that loads Service.exe as a managed assembly.
$SHIM_EXE    = "Docentric.D365FO.DRAServiceShim.exe"

# File extensions that are skipped during the binary copy. These are SQLite
# write-ahead log files created by Visual Studio or other indexers. They are
# transient, not part of the DRA product, and are typically held open by
# another process, so attempting to overwrite them would produce a
# System.IO.IOException and abort the copy unnecessarily.
$SKIP_EXTENSIONS = @('.db-shm', '.db-wal', '.db')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prints a cyan section-header line to the console, visually separating update steps.
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
    script from running without the required elevation. The #Requires directive
    at the top of the file also enforces this, but the explicit check here
    provides a clearer error message in edge cases where the directive is bypassed.
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
    typos or a non-default DRA installation location before any files are
    copied or services are stopped.
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
    reminding the caller to compile the Docentric.D365FO.DRAServiceShim project
    before running this script. The shim must be rebuilt whenever the DRA
    assemblies it depends on have changed (e.g. after a DRA version upgrade).
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
    Stops a Windows service and waits for it to reach the Stopped state.
.PARAMETER ServiceName
    The SCM service name to stop (e.g. "DRA1").
.PARAMETER TimeoutSeconds
    Maximum number of seconds to wait for the service to reach Stopped after
    Stop-Service returns. Defaults to 30 seconds. If the service is still not
    stopped after the timeout a warning is emitted but execution continues, so
    that the caller can still attempt the file copy (locked files will be
    skipped individually with their own warnings).
.OUTPUTS
    [bool] Returns $true if the service was Running and has been stopped.
           Returns $false if the service was already stopped or was not found.
           The return value is used by the main loop to decide whether to
           restart the service after the binary update.
#>
function Stop-ServiceAndWait([string]$ServiceName, [int]$TimeoutSeconds = 30) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warn "Service '$ServiceName' not found -- skipping stop"
        return $false
    }
    if ($svc.Status -ne "Running") {
        Write-OK "Service '$ServiceName' is already stopped"
        return $false
    }
    Write-Step "Stopping service: $ServiceName"
    Stop-Service -Name $ServiceName -Force
    # Poll once per second until the service reaches Stopped or the timeout expires.
    $waited = 0
    while ((Get-Service -Name $ServiceName).Status -ne "Stopped" -and $waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $waited++
    }
    if ((Get-Service -Name $ServiceName).Status -eq "Stopped") {
        Write-OK "Service stopped: $ServiceName"
    } else {
        Write-Warn "Service '$ServiceName' did not stop within $TimeoutSeconds s -- files may be in use"
    }
    return $true
}

<#
.SYNOPSIS
    Overwrites an existing instance binary directory with updated DRA files and
    refreshes the shim executable and its config.
.PARAMETER DestPath
    The per-instance binary directory to update (e.g. C:\DRAInstances\DRA1).
    If this directory does not exist a warning is emitted and the function
    returns without throwing, so a missing instance does not abort the loop.
.PARAMETER SourcePath
    The DRA source installation directory to copy updated binaries from
    (value of -DRASourcePath).
.PARAMETER ShimSrc
    Full path to the (re)compiled Docentric.D365FO.DRAServiceShim.exe
    (value of -ShimExePath).
.DESCRIPTION
    Iterates SourcePath recursively and copies every file into the matching
    location under DestPath, overwriting existing files. Sub-directories are
    created as needed. Files whose extension is in SKIP_EXTENSIONS (SQLite
    transient files) are silently skipped. Files that cannot be overwritten
    due to an IOException (e.g. still held open by a process that did not stop
    in time) are skipped with a warning rather than aborting the update.

    After the DRA binary copy, the shim executable and its config file are
    written last so they cannot be overwritten by a stale copy that might
    exist in SourcePath.
#>
function Update-InstanceBinDirectory([string]$DestPath, [string]$SourcePath, [string]$ShimSrc) {
    if (-not (Test-Path $DestPath)) {
        Write-Warn "Instance bin directory not found, skipping: $DestPath"
        return
    }

    Write-Step "Updating binaries in: $DestPath"

    Get-ChildItem -Path $SourcePath -Recurse | ForEach-Object {
        # Build the destination path by stripping the source root prefix.
        $relativePath = $_.FullName.Substring($SourcePath.TrimEnd('\').Length + 1)
        $destItem     = Join-Path $DestPath $relativePath

        # Ensure sub-directories exist in the destination.
        if ($_.PSIsContainer) {
            New-Item -Path $destItem -ItemType Directory -Force | Out-Null
            return
        }

        # Skip SQLite transient files -- they are not part of the DRA product
        # and are typically locked by an indexer.
        if ($SKIP_EXTENSIONS -contains $_.Extension.ToLower()) {
            Write-Warn "Skipping transient file: $($_.Name)"
            return
        }

        try {
            Copy-Item -Path $_.FullName -Destination $destItem -Force
        }
        catch [System.IO.IOException] {
            # A locked file is non-fatal: warn and continue so the rest of the
            # binaries are updated even if one file cannot be replaced.
            Write-Warn "Skipping locked file: $($_.Name) -- $_"
        }
    }

    Write-OK "DRA binaries updated"

    # Overwrite the shim executable last so it is not replaced by any older
    # copy that may be present in DRASourcePath.
    Copy-Item -Path $ShimSrc -Destination (Join-Path $DestPath $SHIM_EXE) -Force
    Write-OK "Docentric.D365FO.DRAServiceShim.exe updated"

    # Overwrite the shim config with Service.exe.config so the CLR uses the
    # same assembly binding redirects for the shim as for the real service.
    Set-ShimConfigBindingRedirects -InstanceBinPath $DestPath
}

<#
.SYNOPSIS
    Overwrites Docentric.D365FO.DRAServiceShim.exe.config with a copy of
    Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe.config.
.PARAMETER InstanceBinPath
    The per-instance binary directory (e.g. C:\DRAInstances\DRA1).
.DESCRIPTION
    The CLR resolves assembly binding redirects from the entry-point executable's
    config file. Because the shim loads Service.exe as an assembly, the redirects
    in Service.exe.config are not inherited -- only those in
    Docentric.D365FO.DRAServiceShim.exe.config apply. Overwriting the shim config
    with the service config is the simplest way to keep them in sync, and it
    automatically picks up any redirects added by future DRA updates.
    If Service.exe.config is absent a warning is emitted and the function returns
    without throwing.
#>
function Set-ShimConfigBindingRedirects([string]$InstanceBinPath) {
    $serviceConfig = Join-Path $InstanceBinPath "Microsoft.Dynamics.AX.Framework.DocumentRouting.Service.exe.config"
    $shimConfig    = Join-Path $InstanceBinPath "$SHIM_EXE.config"

    if (-not (Test-Path $serviceConfig)) {
        Write-Warn "Service.exe.config not found in bin dir -- skipping shim config update: $serviceConfig"
        return
    }

    Copy-Item -Path $serviceConfig -Destination $shimConfig -Force
    Write-OK "Shim config overwritten from Service.exe.config"
}

<#
.SYNOPSIS
    Prints a post-update summary table of all updated DRA instances.
.PARAMETER Updated
    Names of all instances that were processed (whether or not their service
    was restarted).
.PARAMETER Restarted
    Names of the instances whose service was running before the update and
    was successfully restarted afterwards. Used to distinguish "restarted"
    from "was already stopped" in the per-instance status lines.
.DESCRIPTION
    Outputs a formatted console report showing the service name, binary
    directory, and restart status for every processed instance, followed by
    a reminder to start services manually if none were restarted.
#>
function Show-Summary([string[]]$Updated, [string[]]$Restarted) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor White
    Write-Host "  Update complete -- $($Updated.Count) instance(s)" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor White
    foreach ($name in $Updated) {
        Write-Host ""
        Write-Host "  Instance : $name" -ForegroundColor Yellow
        Write-Host "  Bin dir  : $(Join-Path $InstancesRoot $name)"
        if ($Restarted -contains $name) {
            Write-Host "  Service  : restarted" -ForegroundColor Green
        } else {
            Write-Host "  Service  : was not running, left stopped" -ForegroundColor Gray
        }
    }
    Write-Host ""
    if ($Restarted.Count -eq 0) {
        Write-Host "  No services were running before the update." -ForegroundColor Gray
        Write-Host "  Start them manually when ready:" -ForegroundColor Gray
        Write-Host "    Get-Service DRA* | Start-Service" -ForegroundColor Gray
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Verify elevation and source paths before touching any services or files.
Assert-Admin
Assert-SourceExists $DRASourcePath
Assert-ShimExists $ShimExePath

# Resolve instance names: honour an explicit list, or auto-discover via SCM.
if ($InstanceNames -and $InstanceNames.Count -gt 0) {
    $resolvedNames = $InstanceNames
} else {
    Write-Step "Discovering services matching pattern: $ServiceNamePattern"
    $resolvedNames = @(Get-Service -Name $ServiceNamePattern -ErrorAction SilentlyContinue |
                       Select-Object -ExpandProperty Name)
    if ($resolvedNames.Count -eq 0) {
        throw "No services found matching pattern '$ServiceNamePattern'. Use -InstanceNames to specify instances explicitly."
    }
    Write-OK "Found $($resolvedNames.Count) service(s): $($resolvedNames -join ', ')"
}

# Track which instances were processed and which had their service restarted
# so Show-Summary can produce accurate per-instance status lines.
$updated   = [System.Collections.Generic.List[string]]::new()
$restarted = [System.Collections.Generic.List[string]]::new()

foreach ($name in $resolvedNames) {
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Magenta
    Write-Host "  Instance: $name" -ForegroundColor Magenta
    Write-Host "===================================================" -ForegroundColor Magenta

    $instanceBinPath = Join-Path $InstancesRoot $name

    # Stop the service and remember whether it was running so we can
    # conditionally restart it after the binary copy.
    $wasRunning = Stop-ServiceAndWait -ServiceName $name

    Update-InstanceBinDirectory `
        -DestPath   $instanceBinPath `
        -SourcePath $DRASourcePath `
        -ShimSrc    $ShimExePath

    # Only restart if the service was running before -- do not start a service
    # that was deliberately stopped or disabled prior to running this script.
    if ($wasRunning) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            Write-Step "Starting service: $name"
            Start-Service -Name $name
            Write-OK "Service started: $name"
            $restarted.Add($name)
        }
    }

    $updated.Add($name)
}

Show-Summary -Updated $updated -Restarted $restarted
