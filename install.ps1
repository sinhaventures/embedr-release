[CmdletBinding()]
param(
    [string]$Version = 'latest'
)

$ErrorActionPreference = 'Stop'

$Repo = 'sinhaventures/embedr-release'
$GitHubApi = "https://api.github.com/repos/$Repo"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Throw-Failure {
    param([string]$Message)
    throw $Message
}

if ($Version -ne 'latest' -and -not $Version.StartsWith('v')) {
    $Version = "v$Version"
}

Write-Host ""
Write-Host "Embedr installer" -ForegroundColor Cyan
Write-Host ""

$Release = $null
try {
    $ReleaseUri = if ($Version -eq 'latest') {
        "$GitHubApi/releases/latest"
    } else {
        "$GitHubApi/releases/tags/$Version"
    }
    $Release = if ($Version -eq 'latest') {
        Invoke-RestMethod -Uri $ReleaseUri -TimeoutSec 30
    } else {
        Invoke-RestMethod -Uri $ReleaseUri -TimeoutSec 30
    }
}
catch {
    Throw-Failure "Failed to load release metadata: $($_.Exception.Message)"
}

$VersionTag = if ($Version -eq 'latest') { $Release.tag_name } else { $Version }
$VersionNumber = $VersionTag.TrimStart('v')
$arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' }
$archLabel = if ($arch -eq 'arm64') { 'ARM64' } else { 'x64' }

if ($Version -eq 'latest') {
    Write-Info "Installing the latest release on Windows ($archLabel)."
} else {
    Write-Info "Installing $VersionTag on Windows ($archLabel)."
}
Write-Success "Resolved version: $VersionTag"

if (-not $Release.assets -or $Release.assets.Count -eq 0) {
    Throw-Failure "No release assets were found for $VersionTag"
}

$asset = $null

if ($arch -eq 'arm64') {
    $asset = $Release.assets | Where-Object {
        $_.name -match 'arm64.*\.exe$' -or $_.name -match 'arm64.*x64.*\.exe$'
    } | Select-Object -First 1
}

if (-not $asset) {
    $asset = $Release.assets | Where-Object {
        $_.name -match 'Setup.*x64\.exe$' -or $_.name -match 'x64.*\.exe$' -or $_.name -match '\.exe$'
    } | Select-Object -First 1
}

if (-not $asset) {
    Write-Host ""
    Write-Host "  Available assets:" -ForegroundColor DarkGray
    foreach ($a in $Release.assets) {
        Write-Host "    - $($a.name)" -ForegroundColor DarkGray
    }
    Throw-Failure "Failed to find a Windows installer for $VersionTag"
}

$TempDir = [System.IO.Path]::GetTempPath()
$ExePath = Join-Path $TempDir ("Embedr-Setup-$VersionNumber-$arch.exe")

Write-Info "Downloading $($asset.name)..."
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ExePath -TimeoutSec 600
}
catch {
    Throw-Failure "Download failed: $($_.Exception.Message)"
}

$ZoneIdentifierPath = "${ExePath}:Zone.Identifier"
if (Test-Path -LiteralPath $ZoneIdentifierPath -ErrorAction SilentlyContinue) {
    try {
        Remove-Item -LiteralPath $ZoneIdentifierPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warn "Could not remove Zone.Identifier: $($_.Exception.Message)"
    }
}

try {
    Unblock-File -Path $ExePath -ErrorAction SilentlyContinue
}
catch {
    Write-Warn "Unblock-File was not available or failed: $($_.Exception.Message)"
}

Write-Info "Starting the Windows installer..."
try {
    Start-Process -FilePath $ExePath
}
catch {
    Throw-Failure "Failed to launch installer: $($_.Exception.Message)"
}

Write-Host ""
Write-Success "The installer is open."
Write-Host "Follow the setup prompts to finish installing Embedr." -ForegroundColor DarkGray
