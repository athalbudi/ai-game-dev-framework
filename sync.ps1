<#
.SYNOPSIS
    Sync semua tool dan template dari repo ke deployed location (~/.config/kilo).
    Jalankan setelah setiap commit yang menyentuh tools/ atau godot-templates/.

.DESCRIPTION
    Menyalin file-file berikut dari repo ke ~/.config/kilo/:
      - tools/*.ps1                            -> ~/.config/kilo/tools/
      - godot-templates/*.gd                   -> ~/.config/kilo/godot-templates/
      - scenarios-templates/*.json             -> ~/.config/kilo/scenarios-templates/
      - game-state-templates/*.gd              -> ~/.config/kilo/game-state-templates/
      - command/*.md                           -> ~/.config/kilo/command/
      - ci-templates/**/* (recursive)          -> ~/.config/kilo/ci-templates/
      - fix-request-template.json              -> ~/.config/kilo/fix-request-template.json
      - VERSION                                -> ~/.config/kilo/VERSION
      - AGENTS.md                              -> ~/.config/kilo/AGENTS.md

    Catatan: direktori agent/ tidak di-sync karena belum ada konten di repo.
    Jika agent/ ditambahkan ke repo di masa depan, tambahkan section sync di sini.

    File yang tidak ada di repo tidak dihapus dari deployed (aman untuk file lokal).

.PARAMETER DryRun
    Tampilkan file yang akan disalin tanpa benar-benar menyalin.

.EXAMPLE
    & ".\sync.ps1"
    & ".\sync.ps1" -DryRun
#>

[CmdletBinding()]
param(
    [switch] $DryRun,
    [string] $GameProjectScriptsDir = ""
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
        # Re-write .gd files without BOM — Godot dan beberapa project punya strict encoding check
        # yang gagal jika file punya BOM (UTF-8 with BOM = EF BB BF di awal file)
        if ($src -match '\.gd$') {
            $raw = [System.IO.File]::ReadAllBytes($dst)
            $startIdx = if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { 3 } else { 0 }
            if ($startIdx -eq 3) {
                $text = [System.Text.Encoding]::UTF8.GetString($raw, 3, $raw.Length - 3)
                $noBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($dst, $text, $noBom)
            }
        }
        Write-Ok (Split-Path $src -Leaf)
        $script:synced++
    } catch {
        Write-Err ("gagal copy " + (Split-Path $src -Leaf) + ": $_")
        $script:errors++
    }
}

Write-Host ""
Write-Host "[sync] ================================================" -ForegroundColor Cyan
Write-Host ("[sync]  Saksi -> ~/.config/kilo" + $(if ($DryRun) { "  [DRY RUN]" } else { "" })) -ForegroundColor Cyan
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

# -- Sync scenarios-templates/*.json -------------------------------------------
Write-Host "[sync] scenarios-templates/" -ForegroundColor DarkGray
$scenSrc = Join-Path $repoRoot "scenarios-templates"
$scenDst = Join-Path $kiloConfig "scenarios-templates"
$scenFiles = @(Get-ChildItem -LiteralPath $scenSrc -Filter "*.json" -ErrorAction SilentlyContinue)
foreach ($f in $scenFiles) {
    Sync-File $f.FullName (Join-Path $scenDst $f.Name)
}

# -- Sync game-state-templates/*.gd --------------------------------------------
Write-Host "[sync] game-state-templates/" -ForegroundColor DarkGray
$gstSrc = Join-Path $repoRoot "game-state-templates"
$gstDst = Join-Path $kiloConfig "game-state-templates"
$gstFiles = @(Get-ChildItem -LiteralPath $gstSrc -Filter "*.gd" -ErrorAction SilentlyContinue)
foreach ($f in $gstFiles) {
    Sync-File $f.FullName (Join-Path $gstDst $f.Name)
}

# -- Sync command/*.md ---------------------------------------------------------
Write-Host "[sync] command/" -ForegroundColor DarkGray
$cmdSrc = Join-Path $repoRoot "command"
$cmdDst = Join-Path $kiloConfig "command"
$cmdFiles = @(Get-ChildItem -LiteralPath $cmdSrc -Filter "*.md" -ErrorAction SilentlyContinue)
foreach ($f in $cmdFiles) {
    Sync-File $f.FullName (Join-Path $cmdDst $f.Name)
}

# -- Sync ci-templates/* -------------------------------------------------------
# Gunakan -Recurse karena file CI berada di subdirektori (ci-templates/.github/workflows/*.yml)
Write-Host "[sync] ci-templates/" -ForegroundColor DarkGray
$ciSrc = Join-Path $repoRoot "ci-templates"
$ciDst = Join-Path $kiloConfig "ci-templates"
$ciFiles = @(Get-ChildItem -LiteralPath $ciSrc -File -Recurse -ErrorAction SilentlyContinue)
foreach ($f in $ciFiles) {
    # Pertahankan struktur subdirektori relatif terhadap ciSrc
    $relPath = $f.FullName.Substring($ciSrc.Length).TrimStart('\', '/')
    Sync-File $f.FullName (Join-Path $ciDst $relPath)
}

# -- Sync ke vendored scripts di game project (opsional) -----------------------
# Jika project game memiliki salinan framework templates di scripts/ mereka sendiri
# (pattern yang umum untuk ErrorTracker.gd, GameStateWriter.gd, ScenarioRunner.gd),
# jalankan dengan -GameProjectScriptsDir untuk sync sekaligus:
#
#   & ".\sync.ps1" -GameProjectScriptsDir "C:\path\ke\game\scripts"
#
# Tanpa parameter ini, hanya ~/.config/kilo yang ter-sync (default behavior).
if ($script:PSBoundParameters.ContainsKey('GameProjectScriptsDir') -and $GameProjectScriptsDir -ne "") {
    Write-Host "[sync] game-scripts/" -ForegroundColor DarkGray
    $gameScriptsDst = $GameProjectScriptsDir
    $frameworkTemplates = @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")
    foreach ($tmpl in $frameworkTemplates) {
        $src = Join-Path $godotSrc $tmpl
        if (Test-Path -LiteralPath $src) {
            Sync-File $src (Join-Path $gameScriptsDst $tmpl)
        }
    }
}

# -- Sync fix-request-template.json ke root kilo config (untuk test-pipeline TEST 8) --
$frTemplate = Join-Path $repoRoot "fix-request-template.json"
if (Test-Path -LiteralPath $frTemplate) {
    Sync-File $frTemplate (Join-Path $kiloConfig "fix-request-template.json")
}

# -- Sync VERSION ke root kilo config -------------------------------------------
$versionFile = Join-Path $repoRoot "VERSION"
if (Test-Path -LiteralPath $versionFile) {
    Sync-File $versionFile (Join-Path $kiloConfig "VERSION")
}

# -- Sync AGENTS.md ke root kilo config -----------------------------------------
# Aturan agent global (lihat agent-rules/) menunjuk ke ~/.config/kilo/AGENTS.md sebagai
# lokasi aturan lengkap. Lokasi itu harus stabil -- menunjuk ke repo tidak bisa diandalkan
# karena repo bisa dipindah, di-rename, atau tidak ada sama sekali di mesin pengguna lain.
$agentsFile = Join-Path $repoRoot "AGENTS.md"
if (Test-Path -LiteralPath $agentsFile) {
    Sync-File $agentsFile (Join-Path $kiloConfig "AGENTS.md")
}

# -- Summary -------------------------------------------------------------------
Write-Host "[sync] ------------------------------------------------" -ForegroundColor DarkGray
$col = if ($errors -gt 0) { "Red" } elseif ($DryRun) { "Cyan" } else { "Green" }
$verb = if ($DryRun) { "akan disalin" } else { "disalin" }
Write-Host ("[sync]  $synced file $verb" + $(if ($errors -gt 0) { ", $errors error" } else { "" })) -ForegroundColor $col
Write-Host "[sync] ================================================" -ForegroundColor Cyan
Write-Host ""

exit $(if ($errors -gt 0) { 1 } else { 0 })
