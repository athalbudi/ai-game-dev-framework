<#
.SYNOPSIS
    Harness screenshot adapter untuk Unity.
    Menghasilkan manifest yang kompatibel dengan AI-assisted game development framework.

.DESCRIPTION
    Adapter ini memungkinkan framework universal digunakan di project Unity.
    Semua komponen analisis (visual-diff, baseline, AI commands) tidak memerlukan
    modifikasi karena manifest schema yang dihasilkan identik dengan Godot harness.

    Cara kerja:
      1. Menjalankan Unity build dengan -executeMethod untuk trigger screenshot tour
      2. Membaca PNG output dari OutputDir
      3. Membaca game_state.json jika ada (Layer 1 telemetry)
      4. Menulis shots-manifest.json dengan schema_version 1.1
      5. Print ringkasan: fase telemetry, file list, timestamp

    Prasyarat di Unity project:
      - Buat static class dengan method yang dipanggil via -executeMethod
      - Method tersebut harus menghasilkan PNG ke OutputDir
      - Opsional: tulis game_state.json ke OutputDir yang sama

    Contoh implementasi di Unity (C#):
      public static class ShotHarness {
          public static void RunShotTour() {
              string outputDir = System.Environment.GetEnvironmentVariable("KILO_SHOTS_DIR")
                                 ?? Application.persistentDataPath + "/shots";
              Directory.CreateDirectory(outputDir);
              // Ambil screenshot setiap layar
              ScreenCapture.CaptureScreenshot(outputDir + "/01_main_menu.png");
              // ... navigasi dan ambil screenshot layar lain
              // Tulis game_state.json jika game sudah punya state
              EditorApplication.Exit(0);
          }
      }

.PARAMETER ProjectPath
    Path absolut ke folder project Unity (yang berisi Assets/).
    Default: direktori kerja saat ini.

.PARAMETER UnityExe
    Path ke Unity executable. Jika kosong, dicari otomatis di lokasi default Unity Hub.

.PARAMETER OutputDir
    Path folder output PNG dan game_state.json.
    Default: %APPDATA%\Unity\shots\<ProjectName>

.PARAMETER ExecuteMethod
    Nama fully-qualified method yang dipanggil via -executeMethod.
    Default: "ShotHarness.RunShotTour"

.PARAMETER BuildTarget
    Build target Unity. Default: "StandaloneWindows64".

.PARAMETER Timeout
    Batas waktu tunggu Unity dalam detik. Default: 180.

.EXAMPLE
    & "$env:USERPROFILE\.config\kilo\tools\shot-harness-unity.ps1" -ProjectPath "C:\dev\mygame"

.EXAMPLE
    & "$env:USERPROFILE\.config\kilo\tools\shot-harness-unity.ps1" `
        -ProjectPath "C:\dev\mygame" `
        -ExecuteMethod "MyNamespace.QA.ShotHarness.RunTour" `
        -OutputDir "C:\dev\mygame\shots-output"
#>

[CmdletBinding()]
param(
    [string] $ProjectPath     = "",
    [string] $UnityExe        = "",
    [string] $OutputDir       = "",
    [string] $ExecuteMethod   = "ShotHarness.RunShotTour",
    [string] $BuildTarget     = "StandaloneWindows64",
    [int]    $Timeout         = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "[unity-shot] $msg"         -ForegroundColor Cyan   }
function Write-Ok   { param($msg) Write-Host "[unity-shot] OK  $msg"     -ForegroundColor Green  }
function Write-Warn { param($msg) Write-Host "[unity-shot] WARN $msg"    -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "[unity-shot] FAIL $msg"    -ForegroundColor Red; exit 1 }

# -- 1. Resolve ProjectPath ---------------------------------------------------
if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Write-Fail "ProjectPath tidak ditemukan: $ProjectPath"
}
# Validasi ini adalah Unity project
if (-not (Test-Path (Join-Path $ProjectPath "Assets") -PathType Container)) {
    Write-Fail "Bukan Unity project — folder Assets/ tidak ditemukan di: $ProjectPath"
}
$projectName = Split-Path $ProjectPath -Leaf
Write-Step "Project: $projectName"

# -- 2. Resolve Unity executable ----------------------------------------------
if ($UnityExe -eq "") {
    $candidates = @(
        # Unity Hub default installations
        "C:\Program Files\Unity\Hub\Editor\*\Editor\Unity.exe",
        "C:\Program Files (x86)\Unity\Hub\Editor\*\Editor\Unity.exe",
        "$env:PROGRAMFILES\Unity\Hub\Editor\*\Editor\Unity.exe"
    )
    foreach ($pattern in $candidates) {
        $found = Get-Item $pattern -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($found) {
            $UnityExe = $found.FullName
            Write-Ok "Unity ditemukan: $UnityExe"
            break
        }
    }
    if ($UnityExe -eq "") {
        Write-Fail "Unity executable tidak ditemukan. Gunakan parameter -UnityExe."
    }
}
if (-not (Test-Path -LiteralPath $UnityExe)) {
    Write-Fail "Unity executable tidak ditemukan: $UnityExe"
}

# -- 3. Resolve OutputDir -----------------------------------------------------
if ($OutputDir -eq "") {
    $OutputDir = Join-Path $env:APPDATA "Unity\shots\$projectName"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
    Write-Step "OutputDir dibuat: $OutputDir"
} else {
    Write-Step "OutputDir: $OutputDir"
}

# -- 4. Jalankan Unity dengan -executeMethod ----------------------------------
Write-Step "Menjalankan Unity shot tour via -executeMethod $ExecuteMethod..."
$ts_start = Get-Date

# Set environment variable agar Unity method tahu output dir
$env:KILO_SHOTS_DIR = $OutputDir

$pngCountBefore = @(Get-ChildItem -LiteralPath $OutputDir -Filter "*.png" -ErrorAction SilentlyContinue).Count
$lastProgress   = $ts_start
$noProgressSec  = 0

try {
    $logFile = Join-Path $OutputDir "unity_shot_log.txt"
    $proc = Start-Process -FilePath $UnityExe `
        -ArgumentList "-batchmode", "-nographics", "-quit",
                      "-projectPath", "`"$ProjectPath`"",
                      "-executeMethod", $ExecuteMethod,
                      "-buildTarget", $BuildTarget,
                      "-logFile", "`"$logFile`"" `
        -PassThru -NoNewWindow

    $timeoutMs       = $Timeout * 1000
    $checkIntervalMs = [Math]::Max(5000, $Timeout * 250)
    $elapsedMs       = 0
    $finished        = $false

    while ($elapsedMs -lt $timeoutMs) {
        $waitMs   = [Math]::Min($checkIntervalMs, $timeoutMs - $elapsedMs)
        $finished = $proc.WaitForExit($waitMs)
        if ($finished) { break }
        $elapsedMs += $waitMs

        # Heartbeat
        $pngCountNow = @(Get-ChildItem -LiteralPath $OutputDir -Filter "*.png" -ErrorAction SilentlyContinue).Count
        if ($pngCountNow -gt $pngCountBefore) {
            $pngCountBefore = $pngCountNow
            $lastProgress   = Get-Date
            $noProgressSec  = 0
            Write-Step "Heartbeat: $pngCountNow PNG dihasilkan..."
        } else {
            $noProgressSec = ([datetime]::Now - $lastProgress).TotalSeconds
        }
    }

    if (-not $finished) {
        $proc.Kill()
        if ($pngCountBefore -eq 0) {
            Write-Fail "Timeout ($Timeout detik) — kemungkinan hang. Tidak ada PNG dihasilkan.`n" +
                       "Pastikan -executeMethod '$ExecuteMethod' ada dan dapat dipanggil."
        } else {
            Write-Fail "Timeout ($Timeout detik) — shot tour tidak selesai. $pngCountBefore PNG tersimpan.`n" +
                       "Cek apakah EditorApplication.Exit(0) dipanggil di akhir method."
        }
    }

    if ($proc.ExitCode -ne 0) {
        Write-Warn "Unity exit code $($proc.ExitCode). Cek log: $logFile"
    }
} catch {
    Write-Fail "Gagal menjalankan Unity: $_"
}

$ts_end  = Get-Date
$elapsed = [Math]::Round(($ts_end - $ts_start).TotalSeconds, 1)
Write-Ok "Unity selesai dalam $elapsed detik"

# -- 5. Baca hasil PNG --------------------------------------------------------
$allPng = Get-ChildItem -LiteralPath $OutputDir -Filter "*.png" -ErrorAction SilentlyContinue |
          Sort-Object Name

$pngCount = $allPng.Count
Write-Step "PNG ditemukan: $pngCount file"

# -- 6. Baca game_state.json (Layer 1, opsional) ------------------------------
$gameStatePath = Join-Path $OutputDir "game_state.json"
$gameState     = $null
$telemetryPhase = if ($pngCount -eq 0) { "prototype" } else { "developing" }

if (Test-Path -LiteralPath $gameStatePath) {
    try {
        $gameState      = Get-Content -LiteralPath $gameStatePath -Raw | ConvertFrom-Json
        $telemetryPhase = "mature"
        Write-Ok "game_state.json ditemukan — fase: mature"
    } catch {
        Write-Warn "game_state.json tidak bisa dibaca: $_"
    }
} else {
    Write-Warn "game_state.json belum ada — fase: $telemetryPhase"
    Write-Warn "Implementasikan ShotHarness untuk menulis game_state.json agar AI mendapat konteks lebih dalam."
}

# -- 7. Tulis shots-manifest.json (schema kompatibel dengan Godot harness) ---
$manifestPath = Join-Path $OutputDir "shots-manifest.json"
$manifestData = [ordered]@{
    schema_version    = "1.1"
    generated_at      = $ts_end.ToString("yyyy-MM-dd HH:mm:ss")
    elapsed_sec       = $elapsed
    shots_dir         = $OutputDir
    project_path      = $ProjectPath
    project_name      = $projectName
    engine            = "unity"
    execute_method    = $ExecuteMethod
    png_count         = $pngCount
    telemetry_phase   = $telemetryPhase
    baseline_age_days = $null
    screenshots       = @($allPng | ForEach-Object {
        [ordered]@{
            file       = $_.Name
            size_kb    = [Math]::Round($_.Length / 1024, 1)
            last_write = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
    })
    game_state = $gameState
}

# Cek baseline staleness
$baselineDir      = Join-Path $OutputDir "baseline"
$baselineManifest = Join-Path $baselineDir "baseline-manifest.json"
if (Test-Path -LiteralPath $baselineManifest) {
    try {
        $bm = Get-Content -LiteralPath $baselineManifest -Raw | ConvertFrom-Json
        if ($bm.generated_at) {
            $baselineDate = [datetime]::ParseExact($bm.generated_at, "yyyy-MM-dd HH:mm:ss", $null)
            $manifestData.baseline_age_days = [Math]::Round(($ts_end - $baselineDate).TotalDays, 1)
        }
    } catch { }
}

$manifestJson = $manifestData | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8
Write-Ok "shots-manifest.json ditulis: $manifestPath"

# -- 8. Ringkasan -------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "[unity-shot] Selesai"                                 -ForegroundColor Cyan
Write-Host "  Engine      : Unity ($BuildTarget)"                 -ForegroundColor Gray
Write-Host "  Project     : $projectName"                         -ForegroundColor White
Write-Host "  PNG         : $pngCount file"                       -ForegroundColor White
Write-Host "  Fase        : $telemetryPhase"                      -ForegroundColor $(switch ($telemetryPhase) { "mature" { "Green" } "developing" { "Cyan" } default { "Yellow" } })
Write-Host "  Manifest    : $manifestPath"                        -ForegroundColor White
Write-Host "  Elapsed     : $elapsed detik"                       -ForegroundColor Gray
Write-Host "---------------------------------------------------" -ForegroundColor Cyan