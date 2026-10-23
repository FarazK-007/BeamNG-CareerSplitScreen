# Packaging & Installation script for Career Mode Split-Screen Co-op Mod
param(
    [switch]$DevHotReload
)
$ErrorActionPreference = "Stop"

$modSourceDir = "d:\Antigravity\BeamNG mod\CareerSplitScreen"
$outputZip = Join-Path $modSourceDir "CareerSplitScreen.zip"
$userModsDir = "C:\Users\gofar\AppData\Local\BeamNG\BeamNG.drive\current\mods"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Packaging Career Mode Split-Screen Mod     " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

if (Test-Path $outputZip) {
    Remove-Item $outputZip -Force
    Write-Host "[+] Removed previous local $outputZip" -ForegroundColor Yellow
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$itemsToInclude = @("lua", "scripts", "art", "ui", "mod_info.json")

$zipArchive = [System.IO.Compression.ZipFile]::Open($outputZip, [System.IO.Compression.ZipArchiveMode]::Create)

foreach ($item in $itemsToInclude) {
    $fullPath = Join-Path $modSourceDir $item
    if (Test-Path $fullPath) {
        $itemObj = Get-Item $fullPath
        if ($itemObj.PSIsContainer) {
            $files = Get-ChildItem -Path $fullPath -Recurse -File
            foreach ($file in $files) {
                # Format entry name with forward slashes for cross-platform zip compatibility
                $relativePath = $file.FullName.Substring($modSourceDir.Length + 1).Replace('\', '/')
                Write-Host "  Adding: $relativePath" -ForegroundColor Gray
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $file.FullName, $relativePath, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        } else {
            $relativePath = (Split-Path $fullPath -Leaf).Replace('\', '/')
            Write-Host "  Adding: $relativePath" -ForegroundColor Gray
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $fullPath, $relativePath, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
}

$zipArchive.Dispose()
Write-Host "[OK] Successfully created: $outputZip" -ForegroundColor Green

if (Test-Path $userModsDir) {
    $destination = Join-Path $userModsDir "CareerSplitScreen.zip"
    Copy-Item -Path $outputZip -Destination $destination -Force
    Write-Host "[OK] Mod installed directly into BeamNG mods folder:" -ForegroundColor Green
    Write-Host "     $destination" -ForegroundColor White
} else {
    Write-Host "[!] Warning: Mods directory not found at $userModsDir" -ForegroundColor Yellow
}

# Direct override deployment to current\lua ensures BeamNG boots with mod overrides directly
$currentDir = "C:\Users\gofar\AppData\Local\BeamNG\BeamNG.drive\current"
if (Test-Path $currentDir) {
    Write-Host "[+] Deploying direct override Lua files to current\lua..." -ForegroundColor Cyan
    $luaSource = Join-Path $modSourceDir "lua"
    Copy-Item -Path "$luaSource\*" -Destination (Join-Path $currentDir "lua") -Recurse -Force
    Write-Host "[OK] Direct Lua files synchronized to $currentDir\lua" -ForegroundColor Green

    if (Test-Path (Join-Path $modSourceDir "art")) {
        $artDest = Join-Path $currentDir "art"
        if (-not (Test-Path $artDest)) { New-Item -ItemType Directory -Force -Path $artDest | Out-Null }
        Copy-Item -Path (Join-Path $modSourceDir "art\*") -Destination $artDest -Recurse -Force
        Write-Host "[OK] Direct art files synchronized to $artDest" -ForegroundColor Green
    }
    if (Test-Path (Join-Path $modSourceDir "ui")) {
        $uiDest = Join-Path $currentDir "ui"
        if (-not (Test-Path $uiDest)) { New-Item -ItemType Directory -Force -Path $uiDest | Out-Null }
        Copy-Item -Path (Join-Path $modSourceDir "ui\*") -Destination $uiDest -Recurse -Force
        Write-Host "[OK] Direct UI files synchronized to $uiDest" -ForegroundColor Green
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Career Split-Screen Mod Installed! Ready!   " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
