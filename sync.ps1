<#
.SYNOPSIS
    Sync semua tool dan template dari repo ke deployed location (~/.config/kilo).
    Jalankan setelah setiap commit yang menyentuh tools/ atau godot-templates/.

.DESCRIPTION
    Menyalin file-file berikut dari repo ke ~/.config/kilo/:
      - tools/*.ps1           -> ~/.config/kilo/tools/
      - godot-templates/*.gd  -> ~/.config/kilo/godot-templates/

    File yang tidak ada di repo tidak dihapus dari deployed (aman untuk file lokal).

.PARAMETER DryRun
    Tampilkan file yang akan disalin tanpa benar-benar menyalin.

.EXAMPLE
    & ".\sync.ps1"
    & ".\sync.ps1" -DryRun
#>

[CmdletBinding()]
param(
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot   = $PSScriptRoot
$kiloConfig = Join-Path $env:USERPROFILE ".config\kilo"
$synced     = 0
$skipped    = 0
$errors     = 0

function Write-Ok   { param($m) Write-Host ("[sync] OK   $m") -ForegroundColor Green  }
function Write-Skip { param($m) Write-Host ("[sync] SKIP $m") -ForegroundColor DarkGray }
function Write-Err  { param($m) Write-Host ("[sync] ERR  $m") -ForegroundColor Red    }
function Write-Dry  { param($m) Write-Host ("[sync] DRY  $m") -ForegroundColor Cyan   }

function Sync-File {
    param([string]$src, [string]$dst)
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Err "src tidak ada: $src"
        $script:errors++
        return
    }
    if ($DryRun) {
        Write-Dry "$src -> $dst"
        $script:synced++
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Ok (Split-Path $src -Leaf)
        $script:synced++
    } catch {
        Write-Err ("gagal copy " + (Split-Path $src -Leaf) + ": $_")
        $script:errors++
    }
}

Write-Host ""
Write-Host "[sync] ================================================" -ForegroundColor Cyan
Write-Host ("[sync]  AI-Game-Dev-Framework -> ~/.config/kilo" + $(if ($DryRun) { "  [DRY RUN]" } else { "" })) -ForegroundColor Cyan
Write-Host "[sync] ================================================" -ForegroundColor Cyan

# -- Sync tools/*.ps1 ----------------------------------------------------------
Write-Host "[sync] tools/" -ForegroundColor DarkGray
$toolsSrc = Join-Path $repoRoot "tools"
$toolsDst = Join-Path $kiloConfig "tools"
$psFiles  = @(Get-ChildItem -LiteralPath $toolsSrc -Filter "*.ps1" -ErrorAction SilentlyContinue)
foreach ($f in $psFiles) {
    Sync-File $f.FullName (Join-Path $toolsDst $f.Name)
}

# -- Sync godot-templates/*.gd -------------------------------------------------
Write-Host "[sync] godot-templates/" -ForegroundColor DarkGray
$godotSrc = Join-Path $repoRoot "godot-templates"
$godotDst = Join-Path $kiloConfig "godot-templates"
$gdFiles  = @(Get-ChildItem -LiteralPath $godotSrc -Filter "*.gd" -ErrorAction SilentlyContinue)
foreach ($f in $gdFiles) {
    Sync-File $f.FullName (Join-Path $godotDst $f.Name)
}

# -- Summary -------------------------------------------------------------------
Write-Host "[sync] ------------------------------------------------" -ForegroundColor DarkGray
$col = if ($errors -gt 0) { "Red" } elseif ($DryRun) { "Cyan" } else { "Green" }
$verb = if ($DryRun) { "akan disalin" } else { "disalin" }
Write-Host ("[sync]  $synced file $verb" + $(if ($errors -gt 0) { ", $errors error" } else { "" })) -ForegroundColor $col
Write-Host "[sync] ================================================" -ForegroundColor Cyan
Write-Host ""

exit $(if ($errors -gt 0) { 1 } else { 0 })
