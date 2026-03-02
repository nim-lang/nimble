$ErrorActionPreference = 'Stop'

# --- Detection ---
$latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/nim-lang/nimble/releases/latest"
$version = $latestRelease.tag_name
if (-not $version) {
    Throw "Could not find latest version."
}

$arch = if ([IntPtr]::Size -eq 8) { "x64" } else { "x32" }
$assetName = "nimble-windows_$arch.zip"
$downloadUrl = "https://github.com/nim-lang/nimble/releases/download/$version/$assetName"

# --- Setup ---
$installDir = Join-Path $HOME ".nimble\bin"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir | Out-Null
}

$tmpDir = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpDir | Out-Null

# --- Download Nimble ---
Write-Host "Downloading Nimble $version for Windows $arch..."
$zipPath = Join-Path $tmpDir "nimble.zip"
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath

Write-Host "Extracting Nimble..."
Expand-Archive -Path $zipPath -DestinationPath $installDir -Force

# --- Download DLLs ---
Write-Host "Downloading required DLLs for Nim..."
$dllZipUrl = "https://nim-lang.org/download/dlls.zip"
$dllZipPath = Join-Path $tmpDir "dlls.zip"
Invoke-WebRequest -Uri $dllZipUrl -OutFile $dllZipPath

Write-Host "Extracting DLLs..."
Expand-Archive -Path $dllZipPath -DestinationPath $installDir -Force

# --- Cleanup ---
Remove-Item -Path $tmpDir -Recurse -Force

# --- Update PATH ---
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$installDir*") {
    Write-Host "Adding $installDir to User PATH..."
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
    # Also update current session
    $env:Path = "$env:Path;$installDir"
}

# --- Success Message ---
Write-Host ""
Write-Host "Nimble installed successfully to $installDir." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Restart your terminal to refresh PATH."
Write-Host "2. Install Nim globally:"
Write-Host "   nimble install -g nim"
Write-Host "3. (Optional) Set up development tools:"
Write-Host "   nimble install -g nimlangserver nph"
Write-Host ""
Write-Host "Note: You may need to restart your terminal for PATH changes to take effect."
