<#
.SYNOPSIS
    Autonomous QA loop untuk AI-assisted game development framework.
    Observe → Detect → Hypothesize → Generate → Run → Analyze → Iterate → Report

.DESCRIPTION
    Script ini mengimplementasikan loop QA yang benar-benar autonomous:
    AI tidak hanya menjalankan scenario yang sudah ada, tetapi mengamati anomali,
    menyusun hipotesis, membuat scenario investigasi baru, dan melakukan iterasi
    sampai tidak ada lagi anomali yang belum diinvestigasi.

    Loop berhenti ketika:
    - Tidak ada anomali baru yang ditemukan
    - Semua anomali critical sudah diinvestigasi
    - MaxIterations tercapai

.PARAMETER ProjectPath
    Path ke folder project Godot. Default: direktori kerja saat ini.

.PARAMETER GodotExe
    Path ke Godot executable. Jika kosong, dicari otomatis.

.PARAMETER MaxIterations
    Batas maksimum iterasi loop. Default: 3.

.PARAMETER Timeout
    Batas waktu per run dalam detik. Default: 180.

.PARAMETER SkipInitialHarness
    Jika di-set, skip fase OBSERVE awal (gunakan manifest yang sudah ada).

.PARAMETER OutputDir
    Folder output laporan. Default: <ShotsDir>\autonomous-qa\

.EXAMPLE
    # Loop autonomous penuh
    & "$env:USERPROFILE\.config\kilo\tools\autonomous-qa.ps1" -ProjectPath "C:\dev\mygame"

.EXAMPLE
    # Gunakan manifest yang sudah ada, langsung ke detect
    & "$env:USERPROFILE\.config\kilo\tools\autonomous-qa.ps1" -ProjectPath "C:\dev\mygame" -SkipInitialHarness

.EXAMPLE
    # Batasi 2 iterasi dengan timeout lebih panjang
    & "$env:USERPROFILE\.config\kilo\tools\autonomous-qa.ps1" -ProjectPath "C:\dev\mygame" -MaxIterations 2 -Timeout 240
#>

[CmdletBinding()]
param(
    [string] $ProjectPath          = "",
    [string] $GodotExe             = "",
    [int]    $MaxIterations        = 3,
    [int]    $Timeout              = 180,
    [switch] $SkipInitialHarness,
    [string] $OutputDir            = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$kiloConfig = Join-Path $env:USERPROFILE ".config\kilo"
$harnessPs1 = Join-Path $kiloConfig "tools\shot-harness.ps1"
$diffPs1    = Join-Path $kiloConfig "tools\visual-diff.ps1"
$ts_session = (Get-Date).ToString("yyyyMMdd_HHmmss")

# ── Auto-migrate manifest jika schema lama ─────────────────────────────────────
function Invoke-SchemaMigrationIfNeeded {
    param([string]$manifestPath)
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    try {
        $m  = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $sv = if ($m.PSObject.Properties["schema_version"]) { $m.schema_version } else { "1.0" }
        if ($sv -ne "1.1") {
            $migScript = Join-Path $kiloConfig "tools\schema-migration.ps1"
            if (Test-Path -LiteralPath $migScript) {
                Write-Warn "Manifest schema $sv terdeteksi — migrasi ke 1.1..."
                & $migScript -ManifestPath $manifestPath -Backup:$true
                Write-Ok "Manifest dimigrasikan ke schema 1.1"
            }
        }
    } catch { }
}

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Loop  { param($iter, $phase, $msg)
    Write-Host "[aq][$iter/$MaxIterations] $phase  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "[aq] OK   $msg" -ForegroundColor Green  }
function Write-Warn  { param($msg) Write-Host "[aq] WARN $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "[aq] FAIL $msg" -ForegroundColor Red    }
function Write-Info  { param($msg) Write-Host "[aq]      $msg" -ForegroundColor Gray   }
function Write-Sep   {
    Write-Host "[aq] ─────────────────────────────────────────────" -ForegroundColor DarkGray }

# ── 1. Resolve ProjectPath ─────────────────────────────────────────────────────
if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $ProjectPath)) { Write-Fail "ProjectPath tidak ditemukan: $ProjectPath"; exit 1 }
$projectName = Split-Path $ProjectPath -Leaf

# ── 2. Resolve ShotsDir ────────────────────────────────────────────────────────
$shotsDir = ""
$projectGodot = Join-Path $ProjectPath "project.godot"
if (Test-Path -LiteralPath $projectGodot) {
    try {
        $content = Get-Content -LiteralPath $projectGodot -Raw
        if ($content -match 'config/name="([^"]+)"') {
            $appName = $Matches[1]
            foreach ($candidate in @("$env:APPDATA\Godot\app_userdata\$appName\shots",
                                     "$env:APPDATA\godot\app_userdata\$appName\shots")) {
                if (Test-Path -LiteralPath $candidate) { $shotsDir = $candidate; break }
            }
            if ($shotsDir -eq "") { $shotsDir = "$env:APPDATA\Godot\app_userdata\$appName\shots" }
        }
    } catch { }
}
if ($shotsDir -eq "") { $shotsDir = Join-Path $ProjectPath "shots" }

if ($OutputDir -eq "") { $OutputDir = Join-Path $shotsDir "autonomous-qa" }
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# ── 3. Resolve Godot executable ────────────────────────────────────────────────
if ($GodotExe -eq "") {
    foreach ($g in @("godot","godot4","godot.exe","godot4.exe")) {
        $found = Get-Command $g -ErrorAction SilentlyContinue
        if ($found) { $GodotExe = $found.Source; break }
    }
    if ($GodotExe -eq "") {
        Write-Warn "Godot tidak ditemukan di PATH — fase RUN akan di-skip"
        Write-Warn "Gunakan -GodotExe untuk specify path"
    }
}

Write-Host ""
Write-Host "[aq] ═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "[aq] AUTONOMOUS QA LOOP — $projectName"              -ForegroundColor Cyan
Write-Host "[aq] MaxIterations: $MaxIterations | Timeout: ${Timeout}s" -ForegroundColor Gray
Write-Host "[aq] ShotsDir: $shotsDir"                            -ForegroundColor Gray
Write-Host "[aq] ═══════════════════════════════════════════════" -ForegroundColor Cyan

# ── State loop ────────────────────────────────────────────────────────────────
$allFindings     = [System.Collections.Generic.List[hashtable]]::new()
$investigatedIds = [System.Collections.Generic.HashSet[string]]::new()
$loopReport      = @{
    project_name   = $projectName
    session_id     = $ts_session
    started_at     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    iterations     = @()
    total_anomalies = 0
    investigated   = 0
    unresolved     = 0
    scenarios_generated = 0
}

# ── Helper: baca dan parse manifest ───────────────────────────────────────────
function Read-Manifest {
    $mPath = Join-Path $shotsDir "shots-manifest.json"
    if (Test-Path -LiteralPath $mPath) {
        Invoke-SchemaMigrationIfNeeded -manifestPath $mPath
        try { return Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json }
        catch { }
    }
    return $null
}

# ── Helper: deteksi anomali dari manifest + diff + scenario result ─────────────
function Detect-Anomalies {
    param($manifest, $scenarioResult = $null)

    $anomalies = [System.Collections.Generic.List[hashtable]]::new()

    if ($manifest -eq $null) {
        $anomalies.Add(@{
            id = "no_manifest"
            type = "coverage"; severity = "critical"
            description = "shots-manifest.json tidak ada"
            suggested_action = "Jalankan shot harness terlebih dahulu"
            step_hint = "screenshot"; target_file = ""
            evidence = @{}
        })
        return $anomalies
    }

    # --- Deteksi 1: Telemetry phase ---
    $phase = $manifest.telemetry_phase
    if ($phase -eq "prototype") {
        $anomalies.Add(@{
            id = "phase_prototype"
            type = "coverage"; severity = "warning"
            description = "Fase prototype — belum ada screenshot"
            suggested_action = "Implementasikan --shot handler"
            step_hint = "screenshot"; target_file = ""
            evidence = @{ telemetry_phase = $phase }
        })
    } elseif ($phase -eq "developing") {
        $anomalies.Add(@{
            id = "phase_developing"
            type = "coverage"; severity = "info"
            description = "Fase developing — game_state belum tersedia"
            suggested_action = "Implementasikan _write_game_state()"
            step_hint = "write_state"; target_file = ""
            evidence = @{ telemetry_phase = $phase; png_count = $manifest.png_count }
        })
    }

    # --- Deteksi 2: Screenshot stale ---
    foreach ($ss in @($manifest.screenshots)) {
        if (-not $ss -or -not $ss.last_write) { continue }
        try {
            $lwTime  = [datetime]::ParseExact($ss.last_write, "yyyy-MM-dd HH:mm:ss", $null)
            $runTime = if ($manifest.generated_at) {
                [datetime]::ParseExact($manifest.generated_at, "yyyy-MM-dd HH:mm:ss", $null)
            } else { Get-Date }
            $ageHours = ($runTime - $lwTime).TotalHours
            if ($ageHours -gt 24) {
                $sev = if ($ageHours -gt 168) { "critical" } else { "warning" }
                $id = "stale_$($ss.file -replace '[^a-zA-Z0-9]','_')"
                if (-not $investigatedIds.Contains($id)) {
                    $anomalies.Add(@{
                        id = $id
                        type = "visual"; severity = $sev
                        description = "Screenshot stale: $($ss.file) ($([math]::Round($ageHours,1)) jam lalu)"
                        suggested_action = "Cek apakah --shot handler masih mencapai kondisi ini"
                        step_hint = "screenshot"; target_file = $ss.file
                        evidence = @{ file = $ss.file; age_hours = [math]::Round($ageHours,1) }
                    })
                }
            }
        } catch { }
    }

    # --- Deteksi 3: Visual regressions dari diff-report ---
    $diffPath = Join-Path $shotsDir "diff\diff-report.json"
    if (Test-Path -LiteralPath $diffPath) {
        try {
            $diff = Get-Content -LiteralPath $diffPath -Raw | ConvertFrom-Json
            foreach ($f in @($diff.files)) {
                if (-not $f) { continue }
                $id = "regression_$($f.file -replace '[^a-zA-Z0-9]','_')"
                if ($f.status -eq "REGRESI" -and -not $investigatedIds.Contains($id)) {
                    $anomalies.Add(@{
                        id = $id
                        type = "visual"; severity = "critical"
                        description = "Visual regression: $($f.file) berubah $($f.change_pct)%"
                        suggested_action = "Investigasi perubahan visual di $($f.file)"
                        step_hint = "screenshot"; target_file = $f.file
                        evidence = @{ file = $f.file; change_pct = $f.change_pct }
                    })
                } elseif ($f.status -eq "HILANG" -and -not $investigatedIds.Contains($id)) {
                    $anomalies.Add(@{
                        id = "missing_$($f.file -replace '[^a-zA-Z0-9]','_')"
                        type = "visual"; severity = "critical"
                        description = "Screenshot hilang dari run terbaru: $($f.file)"
                        suggested_action = "Cek apakah --shot handler masih menghasilkan file ini"
                        step_hint = "screenshot"; target_file = $f.file
                        evidence = @{ file = $f.file; status = "HILANG" }
                    })
                }
            }
        } catch { }
    }

    # --- Deteksi 4: State anomalies ---
    $gs = $manifest.game_state
    if ($gs) {
        $player = if ($gs.PSObject.Properties["player"]) { $gs.player } else { $null }
        if ($player) {
            $hp     = if ($player.hp     -ne $null) { [double]$player.hp }     else { -1 }
            $hpMax  = if ($player.hp_max -ne $null) { [double]$player.hp_max } else { -1 }
            $alive  = $player.is_alive
            if ($hp -eq 0 -and $alive -eq $true -and -not $investigatedIds.Contains("state_hp_alive_mismatch")) {
                $anomalies.Add(@{
                    id = "state_hp_alive_mismatch"
                    type = "state"; severity = "critical"
                    description = "State mismatch: hp=0 tapi is_alive=true"
                    suggested_action = "Investigasi UI binding health bar"
                    step_hint = "assert_state"; target_file = ""
                    evidence = @{ "player.hp" = $hp; "player.is_alive" = $alive }
                })
            }
        }

        # Coverage shots_taken vs png_count
        # Toleransi 20: png_count termasuk zoom crops, scenario screenshots (bisa sampai 13+),
        # dan duplicate dari hot-reload Godot 4.7 — bukan semua PNG dari _shot_tour
        if ($gs.PSObject.Properties["shots_taken"] -and $gs.shots_taken -ne $null) {
            $taken = [int]$gs.shots_taken
            $count = [int]$manifest.png_count
            if ([math]::Abs($taken - $count) -gt 20 -and -not $investigatedIds.Contains("state_shots_mismatch")) {
                $anomalies.Add(@{
                    id = "state_shots_mismatch"
                    type = "state"; severity = "warning"
                    description = "Mismatch besar: shots_taken=$taken vs png_count=$count (selisih > 20)"
                    suggested_action = "Cek counter shots_taken di --shot handler; selisih kecil (<20) normal karena zoom crops dan scenario screenshots"
                    step_hint = "write_state"; target_file = ""
                    evidence = @{ shots_taken = $taken; png_count = $count }
                })
            }
        }
    }

    # --- Deteksi 5: Scenario failures ---
    if ($scenarioResult) {
        # Suport kedua nama field: step_results (ScenarioRunner baru) dan steps (lama)
        $stepsField = if ($scenarioResult.PSObject.Properties["step_results"]) { "step_results" } else { "steps" }
        foreach ($step in @($scenarioResult.$stepsField)) {
            if (-not $step -or $step.status -ne "fail") { continue }
            # step_results pakai field "step" (index) + "reason"; format lama pakai "id" + "note"
            $stepId   = if ($step.PSObject.Properties["step"])   { $step.step }   `
                        elseif ($step.PSObject.Properties["id"]) { $step.id }     else { "?" }
            $stepNote = if ($step.PSObject.Properties["reason"]) { $step.reason } `
                        elseif ($step.PSObject.Properties["note"]) { $step.note } else { "" }
            $stepType = if ($step.PSObject.Properties["type"])   { $step.type }   else { "" }
            $id = "scenario_fail_$($stepId -replace '[^a-zA-Z0-9]','_')"
            if (-not $investigatedIds.Contains($id)) {
                $anomalies.Add(@{
                    id = $id
                    type = "scenario"; severity = "critical"
                    description = "Scenario step fail: [$stepType] $stepNote"
                    suggested_action = "Investigasi kondisi yang menyebabkan step ini gagal"
                    step_hint = $stepType; target_file = ""
                    evidence = @{ step_id = $stepId; step_type = $stepType; note = $stepNote }
                })
            }
        }
    }

    # Deteksi 6: Scenario drift
    if ($projectPath -ne "") {
        $driftItems = @(Detect-ScenarioDrift -projectPath $projectPath -manifest $manifest)
        foreach ($d in $driftItems) {
            if (-not ($anomalies | Where-Object { $_.id -eq $d.id })) {
                $anomalies.Add($d)
            }
        }
    }

    return $anomalies
}

# ── Helper: generate scenario JSON dari anomali ────────────────────────────────
# -- Helper: deteksi scenario drift
function Detect-ScenarioDrift {
    param([string]$projectPath, $manifest)
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $scenariosDir = Join-Path $projectPath "scenarios"
    if (-not (Test-Path -LiteralPath $scenariosDir)) { return $results }
    $scenarioFiles = Get-ChildItem -LiteralPath $scenariosDir -Filter "*.json" -ErrorAction SilentlyContinue
    if (-not $scenarioFiles) { return $results }
    $phase = if ($manifest -and $manifest.PSObject.Properties["telemetry_phase"]) { $manifest.telemetry_phase } else { "unknown" }
    foreach ($sf in $scenarioFiles) {
        try {
            $scenario   = Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json
            $steps      = @($scenario.steps)
            $rawContent = Get-Content -LiteralPath $sf.FullName -Raw
            $issues     = [System.Collections.Generic.List[string]]::new()
            $assertCount = @($steps | Where-Object { $_.type -eq "assert_state" }).Count
            $writeCount  = @($steps | Where-Object { $_.type -eq "write_state" }).Count
            $age         = [math]::Round(((Get-Date) - $sf.LastWriteTime).TotalDays, 1)
            if (-not ($steps | Where-Object { $_.type -eq "screenshot" })) {
                $issues.Add("Tidak ada step screenshot")
            }
            if ($assertCount -gt 0 -and $writeCount -eq 0) {
                $issues.Add("assert_state ada tapi write_state tidak ada")
            }
            if ($age -gt 30) {
                $issues.Add("Scenario berumur $age hari -- mungkin tidak relevan")
            }
            if ($assertCount -gt 0 -and $phase -ne "mature") {
                $issues.Add("assert_state di fase ${phase} -- akan di-skip")
            }
            if ($steps.Count -le 5 -and $rawContent -match "SESUAIKAN") {
                $issues.Add("Masih berisi placeholder SESUAIKAN -- belum dikonfigurasi")
            }
            if ($issues.Count -gt 0) {
                $safeName = $sf.BaseName -replace "[^a-zA-Z0-9]", "_"
                $sev = if ($issues | Where-Object { $_ -match "assert_state|SESUAIKAN" }) { "warning" } else { "info" }
                $results.Add(@{
                    id               = "drift_$safeName"
                    type             = "scenario_drift"
                    severity         = $sev
                    description      = "Scenario drift: $($sf.Name) -- $($issues.Count) masalah"
                    suggested_action = "Review dan update: $($sf.FullName)"
                    step_hint        = "log"
                    target_file      = $sf.Name
                    evidence         = @{ file = $sf.Name; age_days = $age; issues = @($issues); step_count = $steps.Count }
                })
            }
        } catch { }
    }
    return $results
}
function Generate-InvestigationScenario {
    param([hashtable[]] $anomalies, [int] $iteration)

    $scenarioId = "aq_investigation_iter${iteration}_$ts_session"
    $steps = [System.Collections.Generic.List[hashtable]]::new()

    $steps.Add(@{ type = "log"; message = "=== AQ INVESTIGATION iter=$iteration ===" })
    $steps.Add(@{ type = "seed_override"; seed = (Get-Random -Maximum 99999); comment = "Deterministik untuk reproduksi" })
    $steps.Add(@{ type = "wait_frames"; frames = 60 })

    # Grup anomali berdasarkan target_file untuk efisiensi
    $visualAnomalies  = @($anomalies | Where-Object { $_.type -eq "visual" -and $_.target_file })
    $stateAnomalies   = @($anomalies | Where-Object { $_.type -eq "state" })
    $scenarioAnomalies = @($anomalies | Where-Object { $_.type -eq "scenario" })

    # Steps untuk visual anomalies
    foreach ($a in $visualAnomalies | Select-Object -First 5) {
        $steps.Add(@{ type = "log"; message = "Investigasi: $($a.description)" })
        $steps.Add(@{ type = "screenshot"; name = "aq_inv_$($a.target_file -replace '[^a-zA-Z0-9]','_')" })
    }

    # Steps untuk state anomalies
    foreach ($a in $stateAnomalies) {
        $steps.Add(@{ type = "log"; message = "Cek state: $($a.description)" })
        $steps.Add(@{ type = "write_state"; comment = "Snapshot state untuk investigasi" })

        # Tambahkan assert_state berdasarkan anomali
        if ($a.id -eq "state_hp_alive_mismatch") {
            $steps.Add(@{
                type = "assert_state"; key = "player.is_alive"; op = "is_true"
                comment = "Verifikasi: player seharusnya masih hidup"
            })
            $steps.Add(@{
                type = "assert_state"; key = "player.hp"; op = "gt"; expected = 0
                comment = "Verifikasi: hp tidak boleh 0 jika player hidup"
            })
        }
    }

    # Steps untuk scenario failures
    foreach ($a in $scenarioAnomalies | Select-Object -First 3) {
        $steps.Add(@{ type = "log"; message = "Re-investigasi fail: $($a.description)" })
        $steps.Add(@{ type = "write_state" })
        $steps.Add(@{ type = "screenshot"; name = "aq_scenario_fail_iter$iteration" })
    }

    # Screenshot dan state final
    $steps.Add(@{ type = "write_state"; comment = "State akhir investigasi" })
    $steps.Add(@{ type = "screenshot"; name = "aq_final_iter$iteration" })
    $steps.Add(@{ type = "log"; message = "=== AQ INVESTIGATION SELESAI iter=$iteration ===" })

    $scenario = [ordered]@{
        scenario_id = $scenarioId
        description = "Auto-generated investigation scenario — iterasi $iteration. Dibuat oleh autonomous-qa.ps1"
        version = "1.0"
        tags = @("auto-generated", "investigation", "autonomous-qa")
        notes = @(
            "Scenario ini dibuat otomatis oleh autonomous-qa loop.",
            "Anomali yang diinvestigasi: $($anomalies.Count) item.",
            "Iterasi: $iteration dari $MaxIterations."
        )
        steps = @($steps)
    }

    return $scenario
}

# ── Helper: run scenario via Godot ────────────────────────────────────────────
function Run-Scenario {
    param([hashtable] $scenario, [int] $iteration)

    if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $projectGodot)) {
        Write-Warn "Skip RUN — Godot tidak tersedia atau project.godot tidak ditemukan"
        return $null
    }

    # Tulis scenario ke ShotsDir
    $scenarioPath = Join-Path $shotsDir "aq_test_scenario.json"
    $scenario | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

    # Juga simpan ke output dir untuk history
    $archivePath = Join-Path $OutputDir "scenario_iter${iteration}_${ts_session}.json"
    Copy-Item -LiteralPath $scenarioPath -Destination $archivePath -Force

    Write-Info "Menjalankan scenario: $($scenario.scenario_id)"
    $ts_run = Get-Date
    try {
        $proc = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$ProjectPath`"", "--", "--scenario", "user://shots/aq_test_scenario.json" `
            -PassThru -NoNewWindow
        $finished = $proc.WaitForExit($Timeout * 1000)
        if (-not $finished) {
            $proc.Kill()
            Write-Warn "Scenario timeout ($($Timeout)s)"
            return $null
        }
        $elapsed = [math]::Round(((Get-Date) - $ts_run).TotalSeconds, 1)
        Write-Ok "Scenario selesai dalam $elapsed detik"
    } catch {
        Write-Warn "Gagal menjalankan scenario: $_"
        return $null
    }

    # Baca hasil — hanya jika file lebih baru dari ts_run (bukan stale dari run sebelumnya)
    $resultPath = Join-Path $shotsDir "scenario_result.json"
    if (Test-Path -LiteralPath $resultPath) {
        $resultFile = Get-Item -LiteralPath $resultPath
        if ($resultFile.LastWriteTime -lt $ts_run) {
            Write-Warn "scenario_result.json lebih lama dari run ini (stale) — mengabaikan"
            return $null
        }
        try {
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            # Archive result
            $archiveResult = Join-Path $OutputDir "result_iter${iteration}_${ts_session}.json"
            Copy-Item -LiteralPath $resultPath -Destination $archiveResult -Force
            return $result
        } catch { }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ══════════════════════════════════════════════════════════════════════════════

# Fase OBSERVE awal
if (-not $SkipInitialHarness) {
    Write-Sep
    Write-Loop 0 "OBSERVE" "Menjalankan shot harness..."
    if (Test-Path -LiteralPath $harnessPs1) {
        # Hashtable-splat agar argumen terikat by-name, bukan posisional
        $harnessCallArgs = @{
            ProjectPath = $ProjectPath
            Timeout     = $Timeout
        }
        if ($GodotExe -ne "") { $harnessCallArgs["GodotExe"] = $GodotExe }
        try {
            & $harnessPs1 @harnessCallArgs
            Write-Ok "Harness selesai"
        } catch {
            Write-Warn "Harness error: $_ — lanjut dengan manifest yang ada"
        }
    } else {
        Write-Warn "shot-harness.ps1 tidak ditemukan, skip OBSERVE"
    }
}

# Fase OBSERVE: jalankan visual-diff setelah harness agar diff-report.json fresh
# Ini memastikan Deteksi 3 (visual regression) di DETECT loop membaca data terkini
if (-not $SkipInitialHarness -and (Test-Path -LiteralPath $diffPs1) -and $shotsDir -ne "") {
    $baselineDir = Join-Path $shotsDir "baseline"
    if (Test-Path -LiteralPath $baselineDir) {
        Write-Loop 0 "OBSERVE" "Menjalankan visual-diff terhadap baseline..."
        try {
            & $diffPs1 -ShotsDir $shotsDir -BaselineDir $baselineDir 2>&1 | Out-Null
            $diffReport = Join-Path $shotsDir "diff\diff-report.json"
            if (Test-Path -LiteralPath $diffReport) {
                $dr = Get-Content -LiteralPath $diffReport -Raw | ConvertFrom-Json
                $regCount = @($dr.files | Where-Object { $_.status -eq "REGRESI" }).Count
                $okCount  = @($dr.files | Where-Object { $_.status -eq "OK" }).Count
                Write-Ok "Visual diff: $okCount OK, $regCount regresi"
            }
        } catch {
            Write-Warn "Visual diff error (non-fatal): $_"
        }
    } else {
        Write-Info "Baseline belum ada — skip visual diff (jalankan /baseline set setelah build stabil)"
    }
}

$lastScenarioResult = $null

for ($iter = 1; $iter -le $MaxIterations; $iter++) {
    Write-Sep
    Write-Loop $iter "DETECT" "Menganalisis anomali..."

    $manifest  = Read-Manifest
    $anomalies = @(Detect-Anomalies -manifest $manifest -scenarioResult $lastScenarioResult)

    # Filter anomali yang belum diinvestigasi
    $newAnomalies = @($anomalies | Where-Object { -not $investigatedIds.Contains($_.id) })
    $criticalNew  = @($newAnomalies | Where-Object { $_.severity -eq "critical" })
    $warningNew   = @($newAnomalies | Where-Object { $_.severity -eq "warning" })

    Write-Info "Anomali baru: $($newAnomalies.Count) ($($criticalNew.Count) critical, $($warningNew.Count) warning)"

    # Tambahkan semua ke allFindings
    foreach ($a in $anomalies) {
        $exists = $allFindings | Where-Object { $_.id -eq $a.id }
        if (-not $exists) { $allFindings.Add($a) }
    }

    # Stop loop jika tidak ada anomali baru yang perlu diinvestigasi
    if ($newAnomalies.Count -eq 0 -or ($criticalNew.Count -eq 0 -and $iter -gt 1)) {
        Write-Ok "Tidak ada anomali critical baru — loop selesai setelah iterasi $iter"
        break
    }

    # HYPOTHESIZE: pilih anomali yang perlu diinvestigasi (priority: critical dulu)
    $toInvestigate = @($criticalNew + $warningNew) | Select-Object -First 8
    Write-Loop $iter "HYPOTHESIZE" "$($toInvestigate.Count) anomali dipilih untuk investigasi"
    foreach ($a in $toInvestigate) {
        Write-Info "  [$($a.severity.ToUpper())] $($a.description)"
    }

    # GENERATE: buat scenario investigasi
    Write-Loop $iter "GENERATE" "Membuat scenario investigasi..."
    $scenario = Generate-InvestigationScenario -anomalies $toInvestigate -iteration $iter
    Write-Ok "Scenario dibuat: $($scenario.scenario_id) ($($scenario.steps.Count) steps)"
    $loopReport.scenarios_generated++

    # RUN: jalankan scenario
    Write-Loop $iter "RUN" "Menjalankan scenario..."
    $lastScenarioResult = Run-Scenario -scenario $scenario -iteration $iter

    # ANALYZE: tandai anomali yang sudah diinvestigasi
    Write-Loop $iter "ANALYZE" "Menganalisis hasil..."
    foreach ($a in $toInvestigate) {
        $investigatedIds.Add($a.id) | Out-Null
        $loopReport.investigated++
    }

    # Catat iterasi
    $iterRecord = @{
        iteration         = $iter
        anomalies_found   = $anomalies.Count
        anomalies_new     = $newAnomalies.Count
        investigated      = $toInvestigate.Count
        scenario_id       = $scenario.scenario_id
        scenario_status   = if ($lastScenarioResult) { $lastScenarioResult.status } else { "not_run" }
    }
    $loopReport.iterations += $iterRecord

    if ($lastScenarioResult) {
        # Suport kedua nama field: steps_pass/steps_fail/steps_skip (ScenarioRunner baru) dan passed/failed/skipped (lama)
        $passed  = if ($lastScenarioResult.PSObject.Properties["steps_pass"])  { $lastScenarioResult.steps_pass }  `
                   elseif ($lastScenarioResult.PSObject.Properties["passed"])  { $lastScenarioResult.passed }  else { 0 }
        $failed  = if ($lastScenarioResult.PSObject.Properties["steps_fail"])  { $lastScenarioResult.steps_fail }  `
                   elseif ($lastScenarioResult.PSObject.Properties["failed"])  { $lastScenarioResult.failed }  else { 0 }
        $skipped = if ($lastScenarioResult.PSObject.Properties["steps_skip"])  { $lastScenarioResult.steps_skip }  `
                   elseif ($lastScenarioResult.PSObject.Properties["skipped"]) { $lastScenarioResult.skipped } else { 0 }
        Write-Ok "Hasil scenario: $($lastScenarioResult.status) ($passed pass / $failed fail / $skipped skip)"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REPORT
# ══════════════════════════════════════════════════════════════════════════════
Write-Sep
Write-Loop "F" "REPORT" "Membuat laporan final..."

$unresolved = @($allFindings | Where-Object { -not $investigatedIds.Contains($_.id) })
$loopReport.total_anomalies     = $allFindings.Count
$loopReport.unresolved          = $unresolved.Count
$loopReport.completed_at        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$loopReport.all_findings        = @($allFindings)
$loopReport.unresolved_findings = @($unresolved)

$reportPath = Join-Path $OutputDir "autonomous-qa-report_${ts_session}.json"
$loopReport | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Ok "Laporan: $reportPath"

# Ringkasan ke stdout
Write-Host ""
Write-Host "[aq] ═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "[aq] AUTONOMOUS QA SELESAI — $projectName"           -ForegroundColor Cyan
Write-Host "[aq] ═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "[aq] Iterasi dijalankan  : $($loopReport.iterations.Count)" -ForegroundColor White
Write-Host "[aq] Total anomali       : $($allFindings.Count)"           -ForegroundColor White
Write-Host "[aq] Diinvestigasi       : $($loopReport.investigated)"     -ForegroundColor $(if($loopReport.investigated -gt 0){"Green"}else{"Gray"})
Write-Host "[aq] Belum diinvestigasi : $($unresolved.Count)"            -ForegroundColor $(if($unresolved.Count -gt 0){"Yellow"}else{"Green"})
Write-Host "[aq] Scenario dibuat     : $($loopReport.scenarios_generated)" -ForegroundColor White

if ($unresolved.Count -gt 0) {
    Write-Host ""
    Write-Host "[aq] ANOMALI YANG MASIH MEMERLUKAN PERHATIAN:" -ForegroundColor Yellow
    foreach ($u in $unresolved) {
        $col = if ($u.severity -eq "critical") { "Red" } else { "Yellow" }
        Write-Host "[aq]   [$($u.severity.ToUpper())] $($u.description)" -ForegroundColor $col
        Write-Host "[aq]          → $($u.suggested_action)" -ForegroundColor Gray
    }
}

Write-Host "[aq] ═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "[aq] Laporan detail: $reportPath" -ForegroundColor Gray
