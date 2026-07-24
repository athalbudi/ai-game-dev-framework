<#
.SYNOPSIS
    Scenario generation feedback loop otomatis untuk AI-assisted game development.
    Observe -> Generate -> Run -> Analyze -> Report dalam satu langkah.

.DESCRIPTION
    Script ini mengimplementasikan loop QA autonomous:
      1. OBSERVE  — jalankan shot harness, ambil screenshot + manifest
      2. GENERATE — invoke AI via Kilo /scenario generate (atau buat template)
      3. RUN      — jalankan scenario yang dihasilkan via harness --scenario
      4. ANALYZE  — baca scenario_result.json + diff-report.json
      5. REPORT   — tulis laporan JSON + ringkasan ke stdout

    Script ini TIDAK membutuhkan game state khusus — berjalan dari fase prototype.
    Semakin banyak data yang tersedia (game_state.json, baseline), semakin dalam analisisnya.

.PARAMETER ProjectPath
    Path ke folder project Godot. Default: direktori kerja saat ini.

.PARAMETER ScenarioName
    Nama scenario yang akan dijalankan. Jika kosong, gunakan smoke test default.
    Cari di <ProjectPath>\scenarios\<nama>.json

.PARAMETER GodotExe
    Path ke Godot executable. Jika kosong, dicari otomatis.

.PARAMETER Timeout
    Batas waktu harness dalam detik. Default: 120.

.PARAMETER SkipHarness
    Jika di-set, skip fase OBSERVE (gunakan manifest yang sudah ada).
    Berguna untuk re-analyze hasil run sebelumnya.

.PARAMETER OutputReport
    Path file laporan JSON output. Default: <ShotsDir>\run-analyze-report.json

.PARAMETER ReproducingScenario
    Path (relatif ke ProjectPath) ke scenario yang dirujuk fix-request.json sebagai
    reproducing_scenario. Jika diisi, file ini otomatis masuk daftar protected file --
    lihat GATE di bawah.

.PARAMETER ProtectedPatterns
    Daftar pola (wildcard, relatif ke ProjectPath, pakai "/" bukan "\") yang tidak boleh
    disentuh oleh patch yang sedang diverifikasi. Default mencakup seluruh scenarios/,
    file ignore-config visual-diff, dan tiga template runtime (ScenarioRunner/
    GameStateWriter/ErrorTracker.gd) yang di-vendor ke scripts/ project.
    Lihat GAME_STATE_SPEC.md bagian "fix-request.json" untuk konteks kenapa gate ini ada:
    fix loop tanpa manusia di antara "patch ditulis" dan "patch dijalankan" tidak punya
    kesempatan lain menangkap patch yang melemahkan alat ukurnya sendiri.

.PARAMETER GateBaseRef
    Git ref pembanding untuk deteksi file yang berubah. Default: "HEAD" (uncommitted
    working-tree changes, cocok untuk patch yang belum di-commit di worktree isolasi).

.EXAMPLE
    # Loop lengkap dengan smoke test
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" -ProjectPath "C:\dev\mygame"

.EXAMPLE
    # Jalankan scenario spesifik
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
        -ProjectPath "C:\dev\mygame" `
        -ScenarioName "save_load"

.EXAMPLE
    # Skip harness, hanya analyze hasil yang sudah ada
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
        -ProjectPath "C:\dev\mygame" `
        -SkipHarness
#>

[CmdletBinding()]
param(
    [string]   $ProjectPath          = "",
    [string]   $ScenarioName         = "",
    [string]   $GodotExe             = "",
    [int]      $Timeout              = 180,
    [switch]   $SkipHarness,
    [string]   $OutputReport         = "",
    [string]   $ReproducingScenario  = "",
    [string[]] $ProtectedPatterns    = @(),
    [string]   $GateBaseRef          = "HEAD"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Phase { param($phase, $msg)
    Write-Host "[run-analyze] $phase  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg)
    Write-Host "[run-analyze] OK   $msg" -ForegroundColor Green }
function Write-Warn  { param($msg)
    Write-Host "[run-analyze] WARN $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg)
    Write-Host "[run-analyze] FAIL $msg" -ForegroundColor Red; exit 1 }
function Write-Info  { param($msg)
    Write-Host "[run-analyze]      $msg" -ForegroundColor Gray }

$kiloConfig = Join-Path $env:USERPROFILE ".config\kilo"
$harnessPs1 = Join-Path $kiloConfig "tools\shot-harness.ps1"

# -- GATE: protected-file hard block -----------------------------------------------
# Tanpa manusia di antara "patch ditulis" dan "patch dijalankan" (fix loop otonom),
# gate ini adalah SATU-SATUNYA kesempatan menangkap patch yang melemahkan alat ukur
# verifikasinya sendiri -- scenario yang diedit supaya lolos, ignore-region yang
# diperluas supaya regresi visual tidak terdeteksi, atau template runtime yang
# diubah supaya assertion tidak lagi menguji apa yang seharusnya. Ini keputusan
# pass/fail itu sendiri, bukan filter tambahan di laporan -- kalau ada match,
# verifikasi GAGAL tanpa terkecuali, terlepas dari bersihnya hasil scenario/visual-diff.
function Test-ProtectedFileViolation {
    param(
        [string]   $RepoPath,
        [string[]] $ProtectedPatterns,
        [string]   $BaseRef = "HEAD"
    )
    $result = [ordered]@{
        violated       = $false
        changed_files  = @()
        protected_hits = @()
    }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath ".git"))) {
        # Bukan git repo -- gate tidak bisa dievaluasi. Fail-closed (anggap violated),
        # bukan fail-open, karena tanpa git tidak ada cara lain memverifikasi scope patch.
        $result.violated = $true
        $result.protected_hits = @("(bukan git repository -- gate tidak bisa dievaluasi, fail-closed)")
        return $result
    }
    Push-Location $RepoPath
    try {
        $unstaged = @(git diff --name-only $BaseRef 2>$null)
        $staged   = @(git diff --name-only --cached $BaseRef 2>$null)
        $changed  = @($unstaged + $staged | Where-Object { $_ -ne "" } | Select-Object -Unique)
    } finally {
        Pop-Location
    }
    $result.changed_files = $changed
    foreach ($file in $changed) {
        $fileNorm = $file -replace '\\', '/'
        foreach ($pattern in $ProtectedPatterns) {
            if ($fileNorm -like $pattern) {
                $result.protected_hits += "$fileNorm (cocok pola: $pattern)"
                $result.violated = $true
            }
        }
    }
    return $result
}

# Default protected patterns -- mulai ketat, longgarkan lewat -ProtectedPatterns
# eksplisit per kasus, bukan sebaliknya (lihat GAME_STATE_SPEC.md).
function Get-DefaultProtectedPatterns {
    param([string] $ReproducingScenario = "")
    $patterns = [System.Collections.Generic.List[string]]::new()
    if ($ReproducingScenario -ne "") {
        $patterns.Add(($ReproducingScenario -replace '\\', '/'))
    }
    $patterns.Add("scenarios/*")
    $patterns.Add("scenarios/*/*")
    $patterns.Add("shots.zoom.json")
    $patterns.Add("visual-diff-ignore.json")
    $patterns.Add("scripts/ScenarioRunner.gd")
    $patterns.Add("scripts/GameStateWriter.gd")
    $patterns.Add("scripts/ErrorTracker.gd")
    return @($patterns)
}

# -- Auto-migrate manifest jika schema lama ----------------------------------------
function Invoke-SchemaMigrationIfNeeded {
    param([string]$manifestPath)
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $sv = if ($m.PSObject.Properties["schema_version"]) { $m.schema_version } else { "1.0" }
        if ($sv -ne "1.1") {
            $migScript = Join-Path $kiloConfig "tools\schema-migration.ps1"
            if (Test-Path -LiteralPath $migScript) {
                Write-Warn "Manifest schema $sv terdeteksi -- migrasi ke 1.1..."
                & $migScript -ManifestPath $manifestPath -Backup:$true
                Write-Ok "Manifest dimigrasikan ke schema 1.1"
            }
        }
    } catch { }
}
# ── 1. Resolve ProjectPath ─────────────────────────────────────────────────────
if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Write-Fail "ProjectPath tidak ditemukan: $ProjectPath"
}
$projectName = Split-Path $ProjectPath -Leaf
Write-Phase "INIT" "Project: $projectName ($ProjectPath)"

# ── 2. Resolve ShotsDir dari konfigurasi harness ──────────────────────────────
# Baca project.godot untuk mapping user:// -> AppData path
# Mendukung config/use_custom_user_dir=true + config/custom_user_dir_name seperti shot-harness.ps1
$shotsDir = ""
$projectGodot = Join-Path $ProjectPath "project.godot"
if (Test-Path -LiteralPath $projectGodot) {
    try {
        $content = Get-Content -LiteralPath $projectGodot -Raw
        if ($content -match 'config/name="([^"]+)"') {
            $appName = $Matches[1]
            # Cek apakah project menggunakan custom user dir
            $useCustomDir  = $content -match 'config/use_custom_user_dir=true'
            $customDirName = ""
            if ($useCustomDir -and $content -match 'config/custom_user_dir_name="([^"]+)"') {
                $customDirName = $Matches[1]
            }
            if ($useCustomDir -and $customDirName -ne "") {
                # Custom user dir: %APPDATA%\<custom_dir_name>\shots
                $safeName = $customDirName -replace '[\\/:*?"<>|]', '_'
                $candidates = @("$env:APPDATA\$safeName\shots")
            } else {
                # Standar Godot: %APPDATA%\Godot\app_userdata\<nama_project>\shots
                $safeName = $appName -replace '[\\/:*?"<>|]', '_'
                $candidates = @(
                    "$env:APPDATA\Godot\app_userdata\$safeName\shots",
                    "$env:APPDATA\godot\app_userdata\$safeName\shots"
                )
            }
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c) { $shotsDir = $c; break }
            }
            # Jika belum ada, gunakan kandidat pertama
            if ($shotsDir -eq "") {
                $shotsDir = $candidates[0]
            }
        }
    } catch { }
}
if ($shotsDir -eq "") {
    $shotsDir = Join-Path $ProjectPath "shots"
}
Write-Info "ShotsDir: $shotsDir"

if ($OutputReport -eq "") {
    $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $OutputReport = Join-Path $shotsDir "run-analyze-report_$ts.json"
}

# ── FASE 1: OBSERVE ────────────────────────────────────────────────────────────
$manifestPath = Join-Path $shotsDir "shots-manifest.json"
$manifest     = $null
$phase1Status = "skip"

if (-not $SkipHarness) {
    Write-Phase "OBSERVE" "Menjalankan shot harness..."

    if (-not (Test-Path -LiteralPath $harnessPs1)) {
        Write-Fail "shot-harness.ps1 tidak ditemukan: $harnessPs1"
    }

    # Panggil langsung tanpa array-splat agar argumen terikat by-name, bukan posisional
    $harnessCallArgs = @{
        ProjectPath = $ProjectPath
        Timeout     = $Timeout
    }
    if ($GodotExe -ne "") { $harnessCallArgs["GodotExe"] = $GodotExe }

    try {
        & $harnessPs1 @harnessCallArgs
        $phase1Status = "ok"
        Write-Ok "Harness selesai"
    } catch {
        Write-Warn "Harness error: $_ — lanjut dengan manifest yang ada"
        $phase1Status = "warn"
    }
} else {
    Write-Phase "OBSERVE" "SkipHarness — menggunakan manifest yang sudah ada"
    $phase1Status = "skipped"
}

# Baca manifest
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $telemetryPhase = $manifest.telemetry_phase
        $pngCount       = $manifest.png_count
        Write-Ok "Manifest: $pngCount PNG, fase=$telemetryPhase"
    } catch {
        Write-Warn "Gagal membaca manifest: $_"
    }
} else {
    Write-Warn "Manifest tidak ditemukan: $manifestPath"
}

# ── FASE 2: GENERATE / RESOLVE SCENARIO ────────────────────────────────────────
Write-Phase "GENERATE" "Resolving scenario..."

$scenarioPath = ""
$scenariosDir = Join-Path $ProjectPath "scenarios"
$phase2Status = "ok"

if ($ScenarioName -ne "") {
    # Cari scenario yang diminta
    $candidates = @(
        (Join-Path $scenariosDir "$ScenarioName.json"),
        (Join-Path $scenariosDir $ScenarioName),
        $ScenarioName
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $scenarioPath = $c; break }
    }
    if ($scenarioPath -eq "") {
        Write-Warn "Scenario '$ScenarioName' tidak ditemukan, fallback ke smoke test"
        $phase2Status = "fallback"
    } else {
        Write-Ok "Scenario: $scenarioPath"
    }
}

if ($scenarioPath -eq "") {
    # Fallback: gunakan smoke.json dari project atau template global
    $fallbackCandidates = @(
        (Join-Path $scenariosDir "smoke.json"),
        (Join-Path $kiloConfig "scenarios-templates\smoke.json")
    )
    foreach ($c in $fallbackCandidates) {
        if (Test-Path -LiteralPath $c) { $scenarioPath = $c; break }
    }

    if ($scenarioPath -eq "") {
        Write-Warn "Tidak ada scenario tersedia. Buat smoke scenario minimal..."
        # Buat smoke scenario minimal inline
        if (-not (Test-Path -LiteralPath $scenariosDir)) {
            New-Item -ItemType Directory -Path $scenariosDir | Out-Null
        }
        $minimalSmoke = @{
            scenario_id = "auto_smoke"
            description = "Auto-generated minimal smoke test"
            version = "1.0"
            tags = @("auto-generated", "smoke", "minimal")
            steps = @(
                @{ type = "log"; message = "=== AUTO SMOKE TEST ===" },
                @{ type = "wait_frames"; frames = 60 },
                @{ type = "screenshot"; name = "auto_smoke_01_launch" },
                @{ type = "write_state" },
                @{ type = "log"; message = "=== AUTO SMOKE TEST SELESAI ===" }
            )
        }
        $scenarioPath = Join-Path $scenariosDir "auto_smoke.json"
        $minimalSmoke | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scenarioPath -Encoding UTF8
        Write-Ok "Smoke scenario minimal dibuat: $scenarioPath"
        $phase2Status = "generated"
    } else {
        Write-Ok "Fallback scenario: $scenarioPath"
        $phase2Status = "fallback"
    }
}

# Salin scenario ke ShotsDir sebagai test_scenario.json
if (-not (Test-Path -LiteralPath $shotsDir)) {
    New-Item -ItemType Directory -Path $shotsDir | Out-Null
}
$testScenarioPath = Join-Path $shotsDir "test_scenario.json"
Copy-Item -LiteralPath $scenarioPath -Destination $testScenarioPath -Force
Write-Info "Scenario disalin ke: $testScenarioPath"

# ── FASE 3: RUN ────────────────────────────────────────────────────────────────
Write-Phase "RUN" "Menjalankan scenario..."

$scenarioResultPath = Join-Path $shotsDir "scenario_result.json"
$scenarioResult     = $null
$phase3Status       = "skip"

# Resolve Godot executable
if ($GodotExe -eq "") {
    $godotCandidates = @("godot", "godot4", "godot.exe", "godot4.exe")
    foreach ($g in $godotCandidates) {
        $found = Get-Command $g -ErrorAction SilentlyContinue
        if ($found) { $GodotExe = $found.Source; break }
    }
    if ($GodotExe -eq "") {
        Write-Warn "Godot executable tidak ditemukan — skip fase RUN"
        Write-Warn "Gunakan -GodotExe untuk specify path, atau pastikan godot ada di PATH"
        $phase3Status = "skip_no_godot"
    }
}

if ($phase3Status -ne "skip_no_godot" -and (Test-Path -LiteralPath $projectGodot)) {
    $ts_run = Get-Date
    try {
        $scenarioFlag = "user://shots/test_scenario.json"
        $proc = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$ProjectPath`"", "--", "--scenario", $scenarioFlag `
            -PassThru -NoNewWindow
        $finished = $proc.WaitForExit($Timeout * 1000)
        if (-not $finished) {
            $proc.Kill()
            Write-Warn "Timeout ($($Timeout) detik) saat menjalankan scenario"
            $phase3Status = "timeout"
        } else {
            $phase3Status = "ok"
            $elapsed = [math]::Round(((Get-Date) - $ts_run).TotalSeconds, 1)
            Write-Ok "Scenario selesai dalam $elapsed detik"
        }
    } catch {
        Write-Warn "Gagal menjalankan scenario: $_"
        $phase3Status = "error"
    }
} elseif ($phase3Status -ne "skip_no_godot") {
    Write-Warn "project.godot tidak ditemukan — skip fase RUN"
    $phase3Status = "skip_no_project"
}

# Baca hasil scenario
if (Test-Path -LiteralPath $scenarioResultPath) {
    try {
        $scenarioResult = Get-Content -LiteralPath $scenarioResultPath -Raw | ConvertFrom-Json
        # Suport kedua kontrak field: steps_pass/steps_fail/steps_skip (ScenarioRunner v1)
        # dan passed/failed/skipped (format lama)
        $passed  = if ($scenarioResult.PSObject.Properties["steps_pass"])  { $scenarioResult.steps_pass }  `
                   elseif ($scenarioResult.PSObject.Properties["passed"])  { $scenarioResult.passed }  else { 0 }
        $failed  = if ($scenarioResult.PSObject.Properties["steps_fail"])  { $scenarioResult.steps_fail }  `
                   elseif ($scenarioResult.PSObject.Properties["failed"])  { $scenarioResult.failed }  else { 0 }
        $skipped = if ($scenarioResult.PSObject.Properties["steps_skip"])  { $scenarioResult.steps_skip }  `
                   elseif ($scenarioResult.PSObject.Properties["skipped"]) { $scenarioResult.skipped } else { 0 }
        $status  = $scenarioResult.status
        Write-Ok "Hasil: $status ($passed pass / $failed fail / $skipped skip)"
    } catch {
        Write-Warn "Gagal membaca scenario_result.json: $_"
    }
}

# ── FASE 4: ANALYZE ────────────────────────────────────────────────────────────
Write-Phase "ANALYZE" "Menganalisis hasil..."

$analysis = @{
    visual_regression = $null
    scenario_findings = @()
    recommendations   = @()
    critical_issues   = @()
}

# 4a: Cek visual regression jika ada baseline
$diffReportPath = Join-Path $shotsDir "diff\diff-report.json"
$diffReport     = $null
$phase4aStatus  = "no_baseline"

if (Test-Path -LiteralPath $diffReportPath) {
    try {
        $diffReport = Get-Content -LiteralPath $diffReportPath -Raw | ConvertFrom-Json
        $regressions = @($diffReport.files | Where-Object { $_.status -eq "REGRESI" })
        $newFiles    = @($diffReport.files | Where-Object { $_.status -eq "FILE_BARU" })
        $missing     = @($diffReport.files | Where-Object { $_.status -eq "HILANG" })

        $analysis.visual_regression = @{
            ok_count        = @($diffReport.files | Where-Object { $_.status -eq "OK" }).Count
            regression_count = $regressions.Count
            new_count       = $newFiles.Count
            missing_count   = $missing.Count
            regressions     = @($regressions | ForEach-Object { $_.file })
        }

        if ($regressions.Count -gt 0) {
            $analysis.critical_issues += "Visual regression: $($regressions.Count) file berubah"
            foreach ($r in $regressions) {
                $analysis.recommendations += "Review visual: $($r.file) ($($r.change_pct)% berubah)"
            }
        }
        $phase4aStatus = "ok"
        Write-Ok "Visual diff: $($regressions.Count) regresi, $($newFiles.Count) baru, $($missing.Count) hilang"
    } catch {
        Write-Warn "Gagal membaca diff-report: $_"
        $phase4aStatus = "error"
    }
} else {
    Write-Info "Tidak ada baseline — skip visual regression check"
    $analysis.recommendations += "Jalankan /baseline set untuk menyimpan baseline visual pertama"
}

# 4b: Analyze scenario results
if ($scenarioResult -ne $null) {
    # Suport kedua nama field: steps_fail/steps_pass/steps_skip/step_results (ScenarioRunner baru)
    # dan failed/passed/skipped/steps (format lama)
    $srFailed  = if ($scenarioResult.PSObject.Properties["steps_fail"])  { $scenarioResult.steps_fail }  `
                 elseif ($scenarioResult.PSObject.Properties["failed"])  { $scenarioResult.failed }  else { 0 }
    $srSkipped = if ($scenarioResult.PSObject.Properties["steps_skip"])  { $scenarioResult.steps_skip }  `
                 elseif ($scenarioResult.PSObject.Properties["skipped"]) { $scenarioResult.skipped } else { 0 }
    $srStepsField = if ($scenarioResult.PSObject.Properties["step_results"]) { "step_results" } else { "steps" }

    if ($srFailed -gt 0) {
        $failedSteps = @($scenarioResult.$srStepsField | Where-Object { $_.status -eq "fail" })
        foreach ($s in $failedSteps) {
            $sId   = if ($s.PSObject.Properties["step"])   { $s.step }   elseif ($s.PSObject.Properties["id"])   { $s.id }   else { "?" }
            $sType = if ($s.PSObject.Properties["type"])   { $s.type }   else { "" }
            $sNote = if ($s.PSObject.Properties["reason"]) { $s.reason } elseif ($s.PSObject.Properties["note"]) { $s.note } else { "" }
            $analysis.scenario_findings += @{
                step_id = $sId
                type    = $sType
                note    = $sNote
            }
            $analysis.critical_issues += "Step fail: [$sType] $sNote"
        }
    }

    if ($srSkipped -gt 0) {
        $analysis.recommendations += "$srSkipped step di-skip — kemungkinan action belum didaftarkan di InputMap atau game_state belum diimplementasikan"
    }

    if ($scenarioResult.status -eq "pass") {
        Write-Ok "Semua step scenario berhasil"
    } elseif ($scenarioResult.status -eq "error") {
        $errMsg = if ($scenarioResult.PSObject.Properties["error"]) { $scenarioResult.error } else { "unknown error" }
        Write-Warn "Scenario error (bukan step fail): $errMsg"
        $analysis.critical_issues += "Scenario error: $errMsg"
    } else {
        Write-Warn "$srFailed step gagal"
    }
}

# 4c: Analyze game state jika tersedia
$gameStatePath = Join-Path $shotsDir "game_state.json"
if (Test-Path -LiteralPath $gameStatePath) {
    try {
        $gameState = Get-Content -LiteralPath $gameStatePath -Raw | ConvertFrom-Json
        Write-Ok "game_state.json tersedia — fase mature"
    } catch {
        Write-Warn "game_state.json tidak bisa dibaca"
        $analysis.recommendations += "game_state.json corrupt atau format tidak valid — cek implementasi _write_game_state()"
    }
} else {
    $analysis.recommendations += "Implementasikan _write_game_state() untuk analisis lebih dalam (fase mature)"
}

# ── FASE GATE: protected-file hard block ──────────────────────────────────────
Write-Phase "GATE" "Cek protected-file violation..."

$effectivePatterns = @(Get-DefaultProtectedPatterns -ReproducingScenario $ReproducingScenario) + @($ProtectedPatterns)
$effectivePatterns = @($effectivePatterns | Select-Object -Unique)
$gateResult = Test-ProtectedFileViolation -RepoPath $ProjectPath -ProtectedPatterns $effectivePatterns -BaseRef $GateBaseRef

if ($gateResult.violated) {
    # Sengaja TIDAK pakai Write-Fail (exit langsung) -- laporan tetap harus ditulis
    # lengkap dengan hasil scenario/visual-diff supaya manusia yang menerima eskalasi
    # punya konteks penuh, bukan cuma "gate gagal".
    Write-Host "[run-analyze] GATE FAIL: patch menyentuh file verifikasi -- eskalasi wajib, tidak lanjut ke merge" -ForegroundColor Red
    foreach ($hit in $gateResult.protected_hits) { Write-Warn "  $hit" }
} else {
    Write-Ok "GATE: tidak ada protected-file violation ($($gateResult.changed_files.Count) file berubah)"
}

# ── FASE 5: REPORT ─────────────────────────────────────────────────────────────
Write-Phase "REPORT" "Membuat laporan..."

$overallStatus = if ($gateResult.violated) { "escalation_required" } `
                 elseif ($analysis.critical_issues.Count -gt 0) { "issues_found" } `
                 else { "clean" }

$report = [ordered]@{
    schema_version   = "1.0"
    generated_at     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    project_name     = $projectName
    project_path     = $ProjectPath
    scenario_used    = (Split-Path $scenarioPath -Leaf)
    overall_status   = $overallStatus
    phases           = [ordered]@{
        observe  = $phase1Status
        generate = $phase2Status
        run      = $phase3Status
        analyze  = @{
            visual_regression = $phase4aStatus
            scenario_results  = if ($scenarioResult) { $scenarioResult.status } else { "not_run" }
        }
        gate     = if ($gateResult.violated) { "violated" } else { "ok" }
    }
    gate             = [ordered]@{
        violated       = $gateResult.violated
        changed_files  = @($gateResult.changed_files)
        protected_hits = @($gateResult.protected_hits)
    }
    analysis         = $analysis
    manifest_summary = if ($manifest) { [ordered]@{
        telemetry_phase = $manifest.telemetry_phase
        png_count       = $manifest.png_count
        generated_at    = $manifest.generated_at
    } } else { $null }
    scenario_summary = if ($scenarioResult) { [ordered]@{
        status       = $scenarioResult.status
        passed       = if ($scenarioResult.PSObject.Properties["steps_pass"])  { $scenarioResult.steps_pass }  `
                       elseif ($scenarioResult.PSObject.Properties["passed"])  { $scenarioResult.passed }  else { 0 }
        failed       = if ($scenarioResult.PSObject.Properties["steps_fail"])  { $scenarioResult.steps_fail }  `
                       elseif ($scenarioResult.PSObject.Properties["failed"])  { $scenarioResult.failed }  else { 0 }
        skipped      = if ($scenarioResult.PSObject.Properties["steps_skip"])  { $scenarioResult.steps_skip }  `
                       elseif ($scenarioResult.PSObject.Properties["skipped"]) { $scenarioResult.skipped } else { 0 }
        duration_sec = if ($scenarioResult.PSObject.Properties["duration_sec"]) { $scenarioResult.duration_sec } else { $null }
    } } else { $null }
}

# Tulis laporan
if (-not (Test-Path -LiteralPath (Split-Path $OutputReport -Parent) -PathType Container)) {
    New-Item -ItemType Directory -Path (Split-Path $OutputReport -Parent) | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputReport -Encoding UTF8
Write-Ok "Laporan: $OutputReport"

# ── Ringkasan ke stdout ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " RUN-AND-ANALYZE SELESAI" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Status      : $overallStatus" -ForegroundColor $(
    if ($overallStatus -eq "clean") { "Green" }
    elseif ($overallStatus -eq "escalation_required") { "Red" }
    else { "Yellow" }
)
Write-Host " Scenario    : $(Split-Path $scenarioPath -Leaf)"
Write-Host " Harness     : $phase1Status"
Write-Host " Run         : $phase3Status"

if ($gateResult.violated) {
    Write-Host ""
    Write-Host " GATE VIOLATION -- eskalasi wajib, TIDAK boleh merge otomatis:" -ForegroundColor Red
    foreach ($hit in $gateResult.protected_hits) {
        Write-Host "   - $hit" -ForegroundColor Red
    }
}

if ($analysis.critical_issues.Count -gt 0) {
    Write-Host ""
    Write-Host " ISSUES DITEMUKAN:" -ForegroundColor Yellow
    foreach ($i in $analysis.critical_issues) {
        Write-Host "   - $i" -ForegroundColor Yellow
    }
}

if ($analysis.recommendations.Count -gt 0) {
    Write-Host ""
    Write-Host " REKOMENDASI:" -ForegroundColor Cyan
    foreach ($r in $analysis.recommendations) {
        Write-Host "   - $r" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host " Laporan detail: $OutputReport" -ForegroundColor Gray
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# Exit code hard block -- orchestrator fix-loop harus bisa percaya exit code saja
# tanpa parsing JSON untuk tahu apakah lanjut ke merge atau eskalasi ke manusia.
if ($gateResult.violated) { exit 1 }
