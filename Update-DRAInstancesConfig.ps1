#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Copies updated config and token cache files to all DRA service instances.

.DESCRIPTION
    After re-authenticating the base DRA installation or changing its configuration,
    run this script to propagate the updated files to every per-instance data directory.

    The following files are copied from ReferenceDataPath to each instance data directory:
      - Microsoft.Dynamics.AX.Framework.DocumentRouting.config
      - TokenCache2.dat
      - Microsoft.Dynamics.AX.Framework.DocumentRouting.ExcludedPrintersSet.xml

    Optionally restarts all matching instance services after the copy.

.PARAMETER InstanceNames
    Service instance names to update (e.g. "DRA1", "DRA2", "DRA3").
    If omitted, all services whose names match the ServiceNamePattern are targeted.

.PARAMETER DataRoot
    Root folder containing per-instance data directories.
    Default: C:\DRAData

.PARAMETER ReferenceDataPath
    Configured DRA data directory to copy credentials and settings from.
    Default: C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing

.PARAMETER ServiceNamePattern
    Wildcard pattern used to discover services when InstanceNames is not supplied.
    Default: DRA*

.PARAMETER RestartServices
    When specified, stops and restarts each instance service after copying files.

.EXAMPLE
    .\Update-DRAInstancesConfig.ps1 -InstanceNames "DRA1","DRA2","DRA3"

.EXAMPLE
    .\Update-DRAInstancesConfig.ps1 -RestartServices

.EXAMPLE
    .\Update-DRAInstancesConfig.ps1 -InstanceNames "DRA1","DRA2" -RestartServices `
        -DataRoot "D:\DRAData"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $InstanceNames,

    [string] $DataRoot = "C:\DRAData",

    [string] $ReferenceDataPath = "C:\ProgramData\Microsoft\Microsoft Dynamics 365 for Operations - Document Routing",

    [string] $ServiceNamePattern = "DRA*",

    [switch] $RestartServices
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$REFERENCE_FILES = @(
    "Microsoft.Dynamics.AX.Framework.DocumentRouting.config"
    "TokenCache2.dat"
    "Microsoft.Dynamics.AX.Framework.DocumentRouting.ExcludedPrintersSet.xml"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Msg) { Write-Host ""; Write-Host "> $Msg" -ForegroundColor Cyan }
function Write-OK([string]$Msg)   { Write-Host "  [OK]   $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }

function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}

function Assert-ReferenceData([string]$Path) {
    $cfg = Join-Path $Path "Microsoft.Dynamics.AX.Framework.DocumentRouting.config"
    if (-not (Test-Path $cfg)) {
        throw "Reference config not found: $cfg`nAuthenticate the base DRA install via the Agent UI first."
    }
}

<#
.SYNOPSIS
    Stops a service and waits up to TimeoutSeconds for it to reach the Stopped state.
#>
function Stop-ServiceAndWait([string]$ServiceName, [int]$TimeoutSeconds = 30) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warn "Service '$ServiceName' not found -- skipping stop"
        return
    }
    if ($svc.Status -ne "Running") {
        Write-OK "Service '$ServiceName' is already stopped"
        return
    }
    Write-Step "Stopping service: $ServiceName"
    Stop-Service -Name $ServiceName -Force
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
}

<#
.SYNOPSIS
    Copies updated reference files into a single instance data directory.
.PARAMETER DataPath
    The per-instance data directory (e.g. C:\DRAData\DRA1).
.PARAMETER ReferencePath
    Source directory to copy files from.
#>
function Update-InstanceData([string]$DataPath, [string]$ReferencePath) {
    if (-not (Test-Path $DataPath)) {
        Write-Warn "Data directory not found, skipping: $DataPath"
        return
    }

    foreach ($file in $REFERENCE_FILES) {
        $src = Join-Path $ReferencePath $file
        $dst = Join-Path $DataPath $file
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $dst -Force
            Write-OK "Copied: $file"
        } else {
            Write-Warn "Not found in reference, skipping: $file"
        }
    }
}

<#
.SYNOPSIS
    Prints a post-update summary table of all updated DRA instances.
#>
function Show-Summary([string[]]$Updated, [string[]]$Restarted) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor White
    Write-Host "  Update complete -- $($Updated.Count) instance(s)" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor White
    foreach ($name in $Updated) {
        Write-Host ""
        Write-Host "  Instance : $name" -ForegroundColor Yellow
        Write-Host "  Data dir : $(Join-Path $DataRoot $name)"
        if ($Restarted -contains $name) {
            Write-Host "  Service  : restarted" -ForegroundColor Green
        }
    }
    Write-Host ""
    if ($Restarted.Count -eq 0) {
        Write-Host "  To apply changes, restart services:" -ForegroundColor Gray
        Write-Host "    Get-Service DRA* | Restart-Service" -ForegroundColor Gray
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Assert-Admin
Assert-ReferenceData $ReferenceDataPath

# Resolve instance names: use supplied list or discover from SCM
if ($InstanceNames -and $InstanceNames.Count -gt 0) {
    $resolvedNames = $InstanceNames
} else {
    Write-Step "Discovering services matching pattern: $ServiceNamePattern"
    $resolvedNames = @(Get-Service -Name $ServiceNamePattern -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($resolvedNames.Count -eq 0) {
        throw "No services found matching pattern '$ServiceNamePattern'. Use -InstanceNames to specify instances explicitly."
    }
    Write-OK "Found $($resolvedNames.Count) service(s): $($resolvedNames -join ', ')"
}

$restarted = [System.Collections.Generic.List[string]]::new()
$updated   = [System.Collections.Generic.List[string]]::new()

foreach ($name in $resolvedNames) {
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Magenta
    Write-Host "  Instance: $name" -ForegroundColor Magenta
    Write-Host "===================================================" -ForegroundColor Magenta

    $instanceDataPath = Join-Path $DataRoot $name

    if ($RestartServices) {
        Stop-ServiceAndWait -ServiceName $name
    }

    Write-Step "Updating data directory: $instanceDataPath"
    Update-InstanceData -DataPath $instanceDataPath -ReferencePath $ReferenceDataPath

    if ($RestartServices) {
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
