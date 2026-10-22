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

$itemsToInclude = @("lua", "scripts", "mod_info.json")

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

# Direct override deployment (only when -DevHotReload is specified)
$currentDir = "C:\Users\gofar\AppData\Local\BeamNG\BeamNG.drive\current"
if (Test-Path $currentDir) {
    if ($DevHotReload) {
        Write-Host "[+] Deploying direct override Lua files for fast dev hot-reload..." -ForegroundColor Cyan
        $luaSource = Join-Path $modSourceDir "lua"
        Copy-Item -Path "$luaSource\*" -Destination (Join-Path $currentDir "lua") -Recurse -Force
        Write-Host "[OK] Direct Lua files synchronized to $currentDir\lua" -ForegroundColor Green
    } else {
        # Clean up legacy loose files so Mod Manager has 100% control over the mod
        $looseGe = Join-Path $currentDir "lua\ge"
        if (Test-Path $looseGe) {
            Remove-Item -Path $looseGe -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[+] Cleaned up loose dev overrides in $looseGe" -ForegroundColor Yellow
        }
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Career Split-Screen Mod Installed! Ready!   " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
