# ============================================================
# RPFM POST-BUILD SCRIPT
# Total War: Warhammer III
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

# Path to rpfm_cli.exe
$RpfmCli = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\rpfm\rpfm_cli.exe"

# The pack we want to modify
$PackFile = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\siege_artillery_ai.pack"

# Folder containing the files produced by your build
$SourceFolder = "C:\Users\Damian\Programming\Total war mods\siege_artillery_ai"

# Temporary staging directory
$TempFolder = Join-Path $env:TEMP "rpfm_postbuild"

# ------------------------------------------------------------
# FILE MAPPING
# ------------------------------------------------------------
#
# SOURCE = path relative to $SourceFolder
# DEST   = path inside the .pack
#
# Example:
#
#   build\my_script.lua
#          ↓
#   MyMod.pack\script\my_mod\my_script.lua
#
# ------------------------------------------------------------

$Files = @{
    "siege_artillery_ai.lua"       = "script\battle\mod\siege_artillery_ai.lua"
    "siege_artillery_targeting.lua"= "script\battle\mod\siege_artillery_targeting.lua"
    "reinforcement_spawn_zones.lua"= "script\battle\mod\reinforcement_spawn_zones.lua"
    "artillery_group.lua"          = "script\battle\mod\artillery_group.lua"
    "artillery_unit.lua"           = "script\battle\mod\artillery_unit.lua"
}

# ------------------------------------------------------------
# CHECKS
# ------------------------------------------------------------

if (-not (Test-Path $RpfmCli)) {
    throw "RPFM CLI not found: $RpfmCli"
}

if (-not (Test-Path $PackFile)) {
    throw "PackFile not found: $PackFile"
}

if (-not (Test-Path $SourceFolder)) {
    throw "Source folder not found: $SourceFolder"
}

# ------------------------------------------------------------
# CLEAN TEMP DIRECTORY
# ------------------------------------------------------------

if (Test-Path $TempFolder) {
    Remove-Item $TempFolder -Recurse -Force
}

New-Item -ItemType Directory -Path $TempFolder | Out-Null

Write-Host ""
Write-Host "========================================"
Write-Host " Move Project Files To Pack"
Write-Host "========================================"
Write-Host ""
Write-Host "Pack:   $PackFile"
Write-Host "Source: $SourceFolder"
Write-Host ""

# ------------------------------------------------------------
# STAGE FILES
# ------------------------------------------------------------

foreach ($Mapping in $Files.GetEnumerator()) {

    $SourceRelative = $Mapping.Key
    $Destination     = $Mapping.Value

    $Source = Join-Path $SourceFolder $SourceRelative
    $Staged = Join-Path $TempFolder $Destination

    Write-Host "Copying:"
    Write-Host "  $Source"
    Write-Host "       -> $Destination"

    if (-not (Test-Path $Source)) {
        throw "Source file not found: $Source"
    }

    # Create destination directory
    $DestinationDirectory = Split-Path $Staged -Parent

    if (-not (Test-Path $DestinationDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $DestinationDirectory `
            -Force | Out-Null
    }

    Copy-Item `
        -Path $Source `
        -Destination $Staged `
        -Force
}

# ------------------------------------------------------------
# ADD STAGED FILES TO PACK
# ------------------------------------------------------------

Write-Host ""
Write-Host "Adding files to PackFile..."
Write-Host ""

& $RpfmCli `
    --game warhammer_3 `
    pack add `
    --pack-path $PackFile `
    --folder-path $TempFolder

if ($LASTEXITCODE -ne 0) {
    throw "RPFM failed with exit code $LASTEXITCODE"
}

# ------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------

Remove-Item $TempFolder -Recurse -Force

Write-Host ""
Write-Host "========================================"
Write-Host " Post-build completed successfully."
Write-Host "========================================"
Write-Host ""