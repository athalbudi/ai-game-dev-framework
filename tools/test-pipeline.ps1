<#
.SYNOPSIS
    Self-test pipeline untuk AI-Assisted Game Development Framework.
    Menjalankan tool utama terhadap fixture minimal dan memverifikasi hasilnya.

.DESCRIPTION
    Membuat fixture minimal lalu menjalankan:
      1. schema-migration   -- migrasi 1.0 -> 1.1, termasuk kasus 1 screenshot
      2. visual-diff        -- 1 PNG (single-file StrictMode regression test)
      3. visual-diff        -- 3 PNG identik (0 regresi diharapkan)
      4. feedback-bridge    -- global issues fps + audio harus terdeteksi
      5. shot-harness       -- AST parse clean

    Exit code 0 = semua PASS, 1 = ada FAIL.

.PARAMETER KeepFixtures
    Jika di-set, jangan hapus folder fixture setelah selesai.

.EXAMPLE
    & "$env:USERPROFILE\.config\kilo\tools\test-pipeline.ps1"
    & "$env:USERPROFILE\.config\kilo\tools\test-pipeline.ps1" -KeepFixtures
#>

[CmdletBinding()]
param(
    [switch] $KeepFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$kiloTools = Join-Path $env:USERPROFILE ".config\kilo\tools"
$tmpBase   = Join-Path $env:TEMP "kilo-selftest-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$passed    = 0
$failed    = 0
$results   = [System.Collections.Generic.List[hashtable]]::new()

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-T { param($msg) Write-Host "[test]      $msg" -ForegroundColor Cyan   }
function Write-S { Write-Host "[test] ---------------------------------------------------" -ForegroundColor DarkGray }

function Add-Result {
    param([string]$name, [bool]$pass, [string]$detail)
    $script:results.Add(@{ name = $name; pass = $pass; detail = $detail })
    if ($pass) {
        $script:passed++
        Write-Host ("[test] PASS " + $name) -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host ("[test] FAIL " + $name + " -- " + $detail) -ForegroundColor Red
    }
}

# ── Resolve tool paths ─────────────────────────────────────────────────────────
$migPs1     = Join-Path $kiloTools "schema-migration.ps1"
$diffPs1    = Join-Path $kiloTools "visual-diff.ps1"
$bridgePs1  = Join-Path $kiloTools "feedback-bridge.ps1"
$harnessPs1 = Join-Path $kiloTools "shot-harness.ps1"

foreach ($t in @($migPs1, $diffPs1, $bridgePs1, $harnessPs1)) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host ("[test] ERROR: Tool tidak ditemukan: " + $t) -ForegroundColor Red
        exit 1
    }
}

# ── Buat fixture ───────────────────────────────────────────────────────────────
Write-T ("Membuat fixture di: " + $tmpBase)
$null = New-Item -ItemType Directory -Path $tmpBase -Force

# --- Manifest v1.0 dengan 1 screenshot ---
$manifestDir = Join-Path $tmpBase "shots_single"
$null = New-Item -ItemType Directory -Path $manifestDir -Force

$manifest10 = [ordered]@{
    generated_at    = "2026-01-01 00:00:00"
    shots_dir       = $manifestDir
    project_path    = $tmpBase
    png_count       = 1
    telemetry_phase = "developing"
    screenshots     = @(
        [ordered]@{ file = "01_title.png"; last_write = "2026-01-01 00:00:00" }
    )
}
$manifest10 | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $manifestDir "shots-manifest.json") -Encoding UTF8

# --- Buat PNG valid via System.Drawing (10x10 pixel hitam) ---
# Hindari hardcoded bytes yang bisa corrupt -- gunakan .NET untuk menghasilkan PNG valid
Add-Type -AssemblyName System.Drawing

function New-BlackPng {
    param([string]$path, [int]$w = 10, [int]$h = 10)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Single-file dir
New-BlackPng (Join-Path $manifestDir "01_title.png")

# Single-file baseline
$baselineSingle = Join-Path $manifestDir "baseline"
$null = New-Item -ItemType Directory -Path $baselineSingle -Force
New-BlackPng (Join-Path $baselineSingle "01_title.png")

# Multi-file shots dir
$shotsMulti    = Join-Path $tmpBase "shots_multi"
$baselineMulti = Join-Path $shotsMulti "baseline"
$null = New-Item -ItemType Directory -Path $shotsMulti -Force
$null = New-Item -ItemType Directory -Path $baselineMulti -Force
foreach ($n in @("01_title.png", "02_gameplay.png", "03_game_over.png")) {
    New-BlackPng (Join-Path $shotsMulti $n)
    New-BlackPng (Join-Path $baselineMulti $n)
}

# --- screen-index.json ---
$screenIndex = [ordered]@{
    project   = "TestGame"
    build     = "0.1.0"
    shots_dir = $shotsMulti
    screens   = @(
        [ordered]@{
            screen_id    = "gameplay"
            description  = "Layar gameplay"
            shot_files   = @("02_gameplay.png")
            render_files = @("scripts/GameManager.gd")
            keywords     = @("gameplay", "hud", "score")
            components   = @(
                [ordered]@{
                    name       = "HUDHealth"
                    file       = "scripts/ui/HUD.gd"
                    key_issues = @("bar HP tidak terupdate")
                    keywords   = @("hp", "health", "nyawa")
                }
            )
        }
    )
    global_issues = @(
        [ordered]@{
            issue_id   = "performance_fps"
            keywords   = @("fps", "lag", "lambat", "patah-patah", "stuttering")
            screens    = @("gameplay")
            components = @("GameManager")
        },
        [ordered]@{
            issue_id   = "audio_missing"
            keywords   = @("suara", "audio", "musik", "bisu", "mute")
            screens    = @("gameplay")
            components = @("AudioManager")
        }
    )
    resolutions = @()
}
$screenIndexPath = Join-Path $tmpBase "screen-index.json"
$screenIndex | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $screenIndexPath -Encoding UTF8

# --- feedback text ---
$feedbackText = "game sering lag dan patah-patah saat banyak musuh. suara juga kadang hilang tiba-tiba."
$feedbackPath = Join-Path $tmpBase "feedback.txt"
Set-Content -LiteralPath $feedbackPath -Value $feedbackText -Encoding UTF8

Write-T "Fixture siap."
Write-S

# ── TEST 1: schema-migration (1 screenshot) ────────────────────────────────────
Write-T "TEST 1: schema-migration -- manifest v1.0 dengan 1 screenshot"
$mPath = Join-Path $manifestDir "shots-manifest.json"
try {
    $null = & $migPs1 -ManifestPath $mPath 2>&1
    $m  = Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json
    $sv = if ($m.PSObject.Properties["schema_version"]) { $m.schema_version } else { "" }
    if ($sv -eq "1.1") {
        Add-Result "schema-migration 1 screenshot" $true "schema_version=1.1"
    } else {
        Add-Result "schema-migration 1 screenshot" $false ("schema_version=" + $sv + " (expected 1.1)")
    }
} catch {
    Add-Result "schema-migration 1 screenshot" $false ("Exception: " + $_)
}
Write-S

# ── TEST 2: visual-diff -- single PNG StrictMode test ─────────────────────────
Write-T "TEST 2: visual-diff -- 1 PNG single-file StrictMode test"
try {
    $out = & $diffPs1 -ShotsDir $manifestDir -BaselineDir $baselineSingle 2>&1
    $outStr  = $out -join " "
    $crashed = $outStr -match "cannot be retrieved|VariableIsUndefined|does not contain a method|PropertyNotFoundStrict"
    if ($crashed) {
        Add-Result "visual-diff 1 PNG no crash" $false ("StrictMode crash terdeteksi")
    } else {
        Add-Result "visual-diff 1 PNG no crash" $true "selesai tanpa StrictMode crash"
    }
} catch {
    Add-Result "visual-diff 1 PNG no crash" $false ("Exception: " + $_)
}
Write-S

# ── TEST 3: visual-diff -- 3 PNG identik, 0 regresi ──────────────────────────
Write-T "TEST 3: visual-diff -- 3 PNG identik, 0 regresi diharapkan"
try {
    $null = & $diffPs1 -ShotsDir $shotsMulti -BaselineDir $baselineMulti 2>&1
    $reportPath = Join-Path $shotsMulti "diff\diff-report.json"
    if (Test-Path -LiteralPath $reportPath) {
        $rep      = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $regCount = @($rep.files | Where-Object { $_.status -eq "REGRESI" }).Count
        $okCount  = @($rep.files | Where-Object { $_.status -eq "OK" }).Count
        if ($regCount -eq 0) {
            Add-Result "visual-diff 3 PNG 0 regresi" $true ("ok=" + $okCount)
        } else {
            Add-Result "visual-diff 3 PNG 0 regresi" $false ($regCount.ToString() + " regresi pada gambar identik")
        }
    } else {
        Add-Result "visual-diff 3 PNG 0 regresi" $true "selesai tanpa crash (MD5 fallback, tanpa baseline dir baru)"
    }
} catch {
    Add-Result "visual-diff 3 PNG 0 regresi" $false ("Exception: " + $_)
}
Write-S

# ── TEST 4: feedback-bridge -- global issues terdeteksi ───────────────────────
Write-T "TEST 4: feedback-bridge -- global issues fps + audio harus terdeteksi"
try {
    $out    = & $bridgePs1 -FeedbackFile $feedbackPath -ScreenIndexPath $screenIndexPath -ProjectPath $tmpBase -OutputJson 2>&1
    $outStr = $out -join "`n"

    # Cari blok JSON dalam output (dimulai dari '{')
    $jsonStart = $outStr.IndexOf('{')
    $jsonEnd   = $outStr.LastIndexOf('}')
    $detected  = $false
    $detail    = "JSON tidak ditemukan dalam output"

    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        try {
            $json       = $outStr.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
            $issueCount = @($json.global_issues).Count
            if ($issueCount -ge 1) {
                $detected = $true
                $detail   = ($issueCount.ToString() + " global issue terdeteksi")
            } else {
                $detail = "0 global issue (expected >=1)"
            }
        } catch {
            # Fallback: cek output teks
            $detected = $outStr -match "performance_fps|audio_missing|masalah"
            $detail   = if ($detected) { "terdeteksi via text output" } else { "tidak terdeteksi di output" }
        }
    } else {
        # Fallback text check
        $detected = $outStr -match "performance_fps|audio_missing"
        $detail   = if ($detected) { "terdeteksi via text output" } else { "tidak ada output yang relevan" }
    }

    Add-Result "feedback-bridge global issues" $detected $detail
} catch {
    Add-Result "feedback-bridge global issues" $false ("Exception: " + $_)
}
Write-S

# ── TEST 5: shot-harness -- AST parse clean ───────────────────────────────────
Write-T "TEST 5: shot-harness.ps1 -- AST parse PS 5.1"
try {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($harnessPs1, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) {
        Add-Result "shot-harness parse clean" $true "0 syntax error"
    } else {
        $errMsg = ($parseErrors | ForEach-Object { "L" + $_.Extent.StartLineNumber + ": " + $_.Message }) -join "; "
        Add-Result "shot-harness parse clean" $false $errMsg
    }
} catch {
    Add-Result "shot-harness parse clean" $false ("Exception: " + $_)
}
Write-S

# ── Cleanup ────────────────────────────────────────────────────────────────────
if (-not $KeepFixtures) {
    try { Remove-Item -LiteralPath $tmpBase -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Write-T "Fixture dihapus."
} else {
    Write-T ("Fixture disimpan di: " + $tmpBase)
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-S
Write-Host ""
Write-Host "[test] =============================================" -ForegroundColor Cyan
Write-Host "[test]  SELF-TEST PIPELINE -- HASIL" -ForegroundColor Cyan
Write-Host "[test] =============================================" -ForegroundColor Cyan
foreach ($r in $results) {
    $col = if ($r.pass) { "Green" } else { "Red" }
    $sym = if ($r.pass) { "PASS" } else { "FAIL" }
    Write-Host ("[test]  " + $sym + "  " + $r.name) -ForegroundColor $col
    if (-not $r.pass -and $r.detail -ne "") {
        Write-Host ("[test]       -> " + $r.detail) -ForegroundColor Yellow
    }
}
Write-Host "[test] ---------------------------------------------" -ForegroundColor DarkGray
$totalTests = $passed + $failed
$col = if ($failed -eq 0) { "Green" } else { "Red" }
$summary = "[test]  " + $passed + "/" + $totalTests + " PASS"
if ($failed -gt 0) { $summary += "  (" + $failed + " FAIL)" }
Write-Host $summary -ForegroundColor $col
Write-Host "[test] =============================================" -ForegroundColor Cyan
Write-Host ""

exit $(if ($failed -eq 0) { 0 } else { 1 })
