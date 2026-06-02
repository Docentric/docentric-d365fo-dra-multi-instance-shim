#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes DRA service instances installed by Install-DRAInstances.ps1.

.DESCRIPTION
    For each named instance:
      - Stops and removes the Windows service via sc.exe
      - Optionally removes binary directory (InstancesRoot\<Name>)
      - Optionally removes data directory (C:\ProgramData\Microsoft\DRA Instance <Name>)

    Data directories are preserved by default. Use -RemoveData to delete them.

.PARAMETER InstanceNames
    Instance names to remove. Pass "ALL" to remove every service whose name starts
    with -ServicePrefix (default "DRA").

.PARAMETER InstancesRoot
    Root folder containing per-instance binary directories.
    Default: C:\DRAInstances

.PARAMETER ServicePrefix
    Used only when -InstanceNames is "ALL". Default: DRA.

.PARAMETER RemoveData
    Also delete data directories under C:\ProgramData\Microsoft\DRA Instance *.
    Requires typing YES at the confirmation prompt.

.PARAMETER RemoveBinaries
    Delete per-instance binary directories under InstancesRoot. Default: true.

.EXAMPLE
    # Remove specific instances, keep data and binaries intact
    .\Uninstall-DRAInstances.ps1 -InstanceNames "DRA1","DRA2" -RemoveBinaries:$false

.EXAMPLE
    # Remove all DRA* services and everything
    .\Uninstall-DRAInstances.ps1 -InstanceNames "ALL" -RemoveData

.EXAMPLE
    # Remove specific instances and all associated files
    .\Uninstall-DRAInstances.ps1 -InstanceNames "DRA1","DRA2","DRA3" -RemoveData
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]] $InstanceNames,

    [string] $InstancesRoot = "C:\DRAInstances",

    [string] $ServicePrefix = "DRA",

    [switch] $RemoveData,

    [switch] $RemoveBinaries = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prints a cyan section-header line to the console, visually separating uninstall steps.
function Write-Step([string]$Msg) { Write-Host ""; Write-Host "> $Msg" -ForegroundColor Cyan }
# Prints a green [OK] status line to indicate a step completed successfully.
function Write-OK([string]$Msg)   { Write-Host "  [OK]   $Msg" -ForegroundColor Green }
# Prints a dark-gray [SKIP] status line when an action is intentionally skipped.
function Write-Skip([string]$Msg) { Write-Host "  [SKIP] $Msg" -ForegroundColor DarkGray }
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
    Resolves the list of DRA instance names to process.
.PARAMETER Names
    The raw value of -InstanceNames as supplied by the caller. When the single
    element is the literal string "ALL", the function queries the SCM for every
    service whose name starts with Prefix and returns those names instead.
.PARAMETER Prefix
    The service-name prefix used to enumerate services when Names is "ALL"
    (value of -ServicePrefix, default "DRA").
.DESCRIPTION
    Returns an array of resolved service names. Returns an empty array (and
    prints a warning) when -InstanceNames ALL is specified but no matching
    services are found, allowing the caller to exit gracefully.
#>
function Resolve-InstanceNames([string[]]$Names, [string]$Prefix) {
    if ($Names.Count -eq 1 -and $Names[0] -eq "ALL") {
        $found = Get-Service -Name "$Prefix*" -ErrorAction SilentlyContinue
        if (-not $found) {
            Write-Host "  No services found with prefix '$Prefix'." -ForegroundColor Yellow
            return @()
        }
        return @($found | Select-Object -ExpandProperty Name)
    }
    return ,$Names
}

<#
.SYNOPSIS
    Stops and removes a single Windows service by name.
.PARAMETER ServiceName
    The SCM service name to stop and delete (e.g. "DRA1").
.DESCRIPTION
    If the service does not exist the function skips silently. If it is
    running, it is stopped with up to 15 seconds of grace time before
    sc.exe delete is called. A warning is emitted (instead of an error)
    if the service entry is still visible after deletion, which can happen
    when a handle to the service is still open and a reboot is required
    to complete removal.
#>
function Remove-DRAService([string]$ServiceName) {
    Write-Step "Removing service: $ServiceName"

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Skip "Service '$ServiceName' not found"
        return
    }

    if ($svc.Status -eq "Running") {
        Stop-Service -Name $ServiceName -Force
        $waited = 0
        while ((Get-Service -Name $ServiceName).Status -eq "Running" -and $waited -lt 15) {
            Start-Sleep -Seconds 1; $waited++
        }
        Write-OK "Stopped"
    }

    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Warn "Service '$ServiceName' still present after delete -- may need a reboot to fully remove"
    } else {
        Write-OK "Service removed"
    }
}

<#
.SYNOPSIS
    Recursively removes a directory if it exists.
.PARAMETER Path
    Full path to the directory to delete.
.PARAMETER Label
    Human-readable label for the directory (e.g. "Binaries" or "Data") used
    in the console output.
.DESCRIPTION
    Calls Remove-Item -Recurse -Force on Path. If the path does not exist,
    a [SKIP] message is printed and the function returns without error,
    making it safe to call unconditionally.
#>
function Remove-Directory([string]$Path, [string]$Label) {
    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force
        Write-OK "Removed $Label`: $Path"
    } else {
        Write-Skip "$Label not found: $Path"
    }
}

<#
.SYNOPSIS
    Prints a post-uninstall summary table for all processed DRA instances.
.PARAMETER Results
    A list of hashtables, each with ServiceName, ServiceStatus, BinariesStatus,
    and DataStatus keys describing the outcome for one instance.
.DESCRIPTION
    Outputs a formatted console report showing, for each instance, whether the
    Windows service, binary directory, and data directory were removed or
    preserved during the uninstall run.
#>
function Show-Summary([System.Collections.Generic.List[hashtable]]$Results) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor White
    Write-Host "  Uninstall complete -- $($Results.Count) instance(s) processed" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor White
    foreach ($r in $Results) {
        Write-Host ""
        Write-Host "  Instance  : $($r.ServiceName)" -ForegroundColor Yellow
        Write-Host "  Service   : $($r.ServiceStatus)"
        Write-Host "  Binaries  : $($r.BinariesStatus)"
        Write-Host "  Data      : $($r.DataStatus)"
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Assert-Admin

$resolvedNames = Resolve-InstanceNames -Names $InstanceNames -Prefix $ServicePrefix

if ($resolvedNames.Count -eq 0) {
    Write-Host "Nothing to uninstall." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Instances to remove: $($resolvedNames -join ', ')" -ForegroundColor White
if ($RemoveData)     { Write-Host "  + Data directories will be DELETED" -ForegroundColor Red }
if ($RemoveBinaries) { Write-Host "  + Binary directories will be deleted" -ForegroundColor Yellow }

if ($RemoveData) {
    $confirm = Read-Host "`nData removal is irreversible. Type YES to confirm"
    if ($confirm -ne "YES") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

$results = [System.Collections.Generic.List[hashtable]]::new()

foreach ($name in $resolvedNames) {
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Magenta
    Write-Host "  Instance: $name" -ForegroundColor Magenta
    Write-Host "===================================================" -ForegroundColor Magenta

    $binPath  = Join-Path $InstancesRoot $name
    $dataPath = Join-Path "C:\ProgramData\Microsoft" "DRA Instance $name"

    Remove-DRAService -ServiceName $name

    $binStatus  = "preserved"
    $dataStatus = "preserved"

    if ($RemoveBinaries) {
        Remove-Directory -Path $binPath -Label "Binaries"
        $binStatus = "removed"
    } else {
        Write-Skip "Binaries preserved: $binPath"
    }

    if ($RemoveData) {
        Remove-Directory -Path $dataPath -Label "Data"
        $dataStatus = "removed"
    } else {
        Write-Skip "Data preserved: $dataPath"
    }

    $results.Add(@{
        ServiceName     = $name
        ServiceStatus   = "removed"
        BinariesStatus  = $binStatus
        DataStatus      = $dataStatus
    })
}

Show-Summary -Results $results
