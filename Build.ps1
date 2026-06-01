<#
.SYNOPSIS
    Builds DraShim.exe and copies all build outputs next to the install script.

.PARAMETER DRASourcePath
    Path to the installed DRA binaries. Must contain Runtime.dll and Service.exe.
    Default: C:\Program Files (x86)\Microsoft Dynamics 365 for Operations - Document Routing

.PARAMETER OutputPath
    Directory where Docentric.D365FO.DRAServiceShim.exe will be copied after a successful build.
    Default: C:\Program Files (x86)\Microsoft Dynamics 365 for Operations - Document Routing

.EXAMPLE
    .\Build.ps1
    .\Build.ps1 -DRASourcePath "D:\DRA"
    .\Build.ps1 -OutputPath "D:\Output"
#>
param(
    [string] $DRASourcePath = "${env:ProgramFiles(x86)}\Microsoft Dynamics 365 for Operations - Document Routing",
    [string] $OutputPath    = "${env:ProgramFiles(x86)}\Microsoft Dynamics 365 for Operations - Document Routing"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DRASourcePath)) {
    throw "DRA source path not found: $DRASourcePath"
}

$slnDir = $PSScriptRoot
Push-Location $slnDir

try {
    Write-Host "Building Docentric.D365FO.DRAServiceShim.exe..." -ForegroundColor Cyan
    dotnet build Docentric.D365FO.DRAServiceShim\Docentric.D365FO.DRAServiceShim.csproj -c Release `
        /p:DRALibPath="$DRASourcePath" `
        --nologo

    if ($LASTEXITCODE -ne 0) { throw "Build failed." }

    $distDir = Join-Path $slnDir "dist"
    $distFiles = Get-ChildItem -Path "$distDir\*.*" -File

    if ($distFiles.Count -eq 0) {
        throw "Build output not found in: $distDir"
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath | Out-Null
    }

    foreach ($file in $distFiles) {
        $dest = Join-Path $OutputPath $file.Name
        Copy-Item $file.FullName $dest -Force
        Write-Host "[OK] $($file.Name) -> $dest" -ForegroundColor Green
    }
} finally {
    Pop-Location
}
