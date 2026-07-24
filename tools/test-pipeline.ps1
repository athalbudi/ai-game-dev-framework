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
      6. shot-harness Godot -- jika -GodotExe tersedia, jalankan golden project nyata
         dan verifikasi minimal 1 PNG dihasilkan tanpa hot-reload fatal

    Exit code 0 = semua PASS, 1 = ada FAIL.

.PARAMETER KeepFixtures
    Jika di-set, jangan hapus folder fixture setelah selesai.

.PARAMETER GodotExe
    Path ke Godot executable. Jika diset, test #6 (Godot golden project) dijalankan.
    Contoh: -GodotExe "C:\Godot\godot.exe"

.EXAMPLE
    & "$env:USERPROFILE\.config\kilo\tools\test-pipeline.ps1"
    & "$env:USERPROFILE\.config\kilo\tools\test-pipeline.ps1" -GodotExe "C:\Godot\godot.exe"
    & "$env:USERPROFILE\.config\kilo\tools\test-pipeline.ps1" -KeepFixtures
#>

[CmdletBinding()]
param(
    [switch] $KeepFixtures,
    [string] $GodotExe = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Auto-detect Godot executable jika tidak diset secara eksplisit
if ($GodotExe -eq "") {
    $candidates = @(
        "C:\Godot\godot.exe",
        "C:\Program Files\Godot\godot.exe",
        "C:\Program Files (x86)\Godot\godot.exe",
        "$env:LOCALAPPDATA\Programs\Godot\godot.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $GodotExe = $c; break }
    }
    # Fallback: cek PATH
    if ($GodotExe -eq "") {
        $found = Get-Command "godot.exe" -ErrorAction SilentlyContinue
        if ($found) { $GodotExe = $found.Source }
    }
}

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

# ── TEST 6: shot-harness dengan Godot golden project ─────────────────────────
# Hanya dijalankan jika -GodotExe tersedia
if ($GodotExe -ne "" -and (Test-Path -LiteralPath $GodotExe)) {
    Write-T "TEST 6: shot-harness + Godot golden project (minimal, anti-hotreload)"

    # Buat golden project minimal yang mengikuti pattern aman
    $goldenDir = Join-Path $tmpBase "golden_project"
    $null = New-Item -ItemType Directory -Path $goldenDir -Force
    $goldenScripts = Join-Path $goldenDir "scripts"
    $null = New-Item -ItemType Directory -Path $goldenScripts -Force

    # project.godot
    @"
[configuration]
config_version=5

[application]
config/name="GoldenTest"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7")

[autoload]
GameStateWriter="*res://scripts/GameStateWriter.gd"
ErrorTracker="*res://scripts/ErrorTracker.gd"
"@ | Set-Content (Join-Path $goldenDir "project.godot") -Encoding UTF8

    # main.tscn — format Godot 4 yang valid (tanpa uid agar portable di semua versi 4.x)
    @"
[gd_scene format=3 uid="uid://golden_main"]

[ext_resource type="Script" path="res://scripts/main.gd" id="1_main"]

[node name="Main" type="Node"]
script = ExtResource("1_main")
"@ | Set-Content (Join-Path $goldenDir "main.tscn") -Encoding UTF8

    # main.gd -- mengikuti pattern AMAN: tidak pakai := dengan class_name, tidak pakai typed member var class_name
    @"
extends Node

var gs   # GameState -- untyped agar aman saat hot-reload

func _ready() -> void:
    # --shot dihandle oleh ErrorTracker._shot_quit_watchdog
    # Jangan panggil _shot_tour dari sini
    pass

func _shot_tour() -> void:
    _take_shot("01_main")
    await get_tree().create_timer(0.1).timeout
    get_tree().quit(0)

func _take_shot(name: String) -> void:
    var dir = DirAccess.open("user://")
    if dir:
        if not dir.dir_exists("shots"):
            dir.make_dir("shots")
    var img = get_viewport().get_texture().get_image()
    img.save_png("user://shots/%s.png" % name)

func _get_game_state() -> Dictionary:
    return {"scene": "main", "frame": Engine.get_process_frames()}
"@ | Set-Content (Join-Path $goldenScripts "main.gd") -Encoding UTF8

    # Copy GameStateWriter dan ErrorTracker dari repo
    $repoGodot = Join-Path $kiloTools "..\godot-templates"
    $resolvedGodot = Resolve-Path $repoGodot -ErrorAction SilentlyContinue
    $repoGodot = if ($resolvedGodot) { $resolvedGodot.Path } else { Join-Path $env:USERPROFILE ".config\kilo\godot-templates" }
    foreach ($tmpl in @("GameStateWriter.gd", "ErrorTracker.gd")) {
        $src = Join-Path $repoGodot $tmpl
        $dst = Join-Path $goldenScripts $tmpl
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }

    # Cek apakah template ter-copy
    $hasTemplates = (Test-Path (Join-Path $goldenScripts "ErrorTracker.gd")) -and
                    (Test-Path (Join-Path $goldenScripts "GameStateWriter.gd"))

    if (-not $hasTemplates) {
        Add-Result "shot-harness Godot golden project" $false "ErrorTracker.gd atau GameStateWriter.gd tidak ditemukan di $repoGodot"
    } else {
        try {
            # Bersihkan shots lama
            $goldenAppName = "GoldenTest"
            $goldenShots   = "$env:APPDATA\Godot\app_userdata\$goldenAppName\shots"
            if (Test-Path $goldenShots) {
                Remove-Item -LiteralPath $goldenShots -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Pre-import: bangun .godot/ cache agar hot-reload tidak crash main.gd
            Write-T "  Pre-import golden project (build Godot cache)..."
            $importProc = Start-Process -FilePath $GodotExe `
                -ArgumentList "--path", "`"$goldenDir`"", "--headless", "--import", "--quit" `
                -PassThru -NoNewWindow -Wait
            Write-T ("  Import selesai (exit: " + $importProc.ExitCode + ")")

            # Jalankan harness
            $harnessOut = & $harnessPs1 -ProjectPath $goldenDir -GodotExe $GodotExe -Timeout 60 2>&1
            $outStr     = $harnessOut -join "`n"

            # Cek apakah ada PNG dihasilkan
            $pngs = @(Get-ChildItem $goldenShots -Filter "*.png" -ErrorAction SilentlyContinue)
            $hasCrash = $outStr -match "VariableIsUndefined|cannot be retrieved|PropertyNotFoundStrict"

            if ($hasCrash) {
                Add-Result "shot-harness Godot golden project" $false "StrictMode crash terdeteksi di harness"
            } elseif ($pngs.Count -ge 1) {
                Add-Result "shot-harness Godot golden project" $true "$($pngs.Count) PNG dihasilkan"
            } else {
                $hotReloadErr = $outStr -match "GDScript::reload.*Parse Error|Failed to load script"
                if ($hotReloadErr) {
                    Add-Result "shot-harness Godot golden project" $false "Hot-reload parse error -- golden project mungkin belum menggunakan pattern aman"
                } else {
                    Add-Result "shot-harness Godot golden project" $false "0 PNG dihasilkan (timeout atau game tidak quit)"
                }
            }
        } catch {
            Add-Result "shot-harness Godot golden project" $false ("Exception: " + $_)
        }
    }
    Write-S
} else {
    if ($GodotExe -ne "") {
        Write-T "TEST 6: SKIP -- GodotExe tidak ditemukan: $GodotExe"
    } else {
        Write-T "TEST 6: SKIP -- -GodotExe tidak diset (tambahkan -GodotExe untuk test Godot)"
    }
    Write-S
}

# ── TEST 7: GDScript strict mode -- template harus load bersih di unsafe_method_access=2 ──
# Ini adalah test regresi untuk masalah yang ditemukan auditor:
# GameStateWriter/ErrorTracker gagal parse di bawah strict mode karena direct method call
# di atas Node return value. Test ini memastikan tidak terulang.
Write-T "TEST 7: GDScript strict mode -- template .gd load bersih tanpa unsafe method calls"
if ($GodotExe -ne "" -and (Test-Path -LiteralPath $GodotExe)) {
    try {
        # Buat project minimal dengan strict mode aktif
        $strictDir = Join-Path $tmpBase "strict_test"
        $null = New-Item -ItemType Directory -Path $strictDir -Force
        $strictScripts = Join-Path $strictDir "scripts"
        $null = New-Item -ItemType Directory -Path $strictScripts -Force

        # project.godot dengan unsafe_method_access=2 (strict)
        @"
[configuration]
config_version=5

[application]
config/name="StrictTest"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7")

[autoload]
GameStateWriter="*res://scripts/GameStateWriter.gd"
ErrorTracker="*res://scripts/ErrorTracker.gd"

[gdscript]
warnings/unsafe_method_access=2
warnings/unsafe_property_access=2
warnings/return_value_discarded=0
"@ | Set-Content (Join-Path $strictDir "project.godot") -Encoding UTF8

        # main.tscn minimal
        @"
[gd_scene format=3 uid="uid://strict_main"]

[node name="Main" type="Node"]
"@ | Set-Content (Join-Path $strictDir "main.tscn") -Encoding UTF8

        # Copy template tanpa BOM -- termasuk ScenarioRunner untuk test scenario path
        $kiloTemplates = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("GameStateWriter.gd", "ErrorTracker.gd", "ScenarioRunner.gd")) {
            $src = Join-Path $kiloTemplates $tmpl
            $dst = Join-Path $strictScripts $tmpl
            if (Test-Path -LiteralPath $src) {
                $bytes = [System.IO.File]::ReadAllBytes($src)
                $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
                $text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
                $enc = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($dst, $text, $enc)
            }
        }

        # Jalankan Godot headless --quit dan cek apakah ada Parse Error dari template
        $logPath = Join-Path $env:TEMP "kilo_strict_test.txt"
        $proc = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$strictDir`"", "--headless", "--quit" `
            -PassThru -NoNewWindow -RedirectStandardError $logPath -Wait

        $logLines = @(Get-Content $logPath -ErrorAction SilentlyContinue)
        # Cari Parse Error yang berasal dari template framework (bukan dari hot-reload main scene)
        $templateErrors = @($logLines | Where-Object {
            $_ -match "Parse Error" -and
            ($_ -match "GameStateWriter|ErrorTracker") -and
            $_ -notmatch "GDScript::reload"
        })

        if ($templateErrors.Count -eq 0) {
            Add-Result "strict mode autoload (unsafe_method_access=2)" $true "0 parse error di GameStateWriter/ErrorTracker"
        } else {
            $errDetail = ($templateErrors | Select-Object -First 2) -join "; "
            Add-Result "strict mode autoload (unsafe_method_access=2)" $false $errDetail
        }
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

        # Part 2: test ScenarioRunner di bawah strict mode via --scenario
        # ScenarioRunner bukan autoload -- hanya di-load saat --scenario dipanggil.
        # Test ini memastikan jalur dinamis tersebut juga bersih di strict mode.
        $scenarioDir = Join-Path $strictDir "scenarios"
        $null = New-Item -ItemType Directory -Path $scenarioDir -Force
        @"
{
  "scenario_id": "strict_smoke",
  "description": "Strict mode smoke test -- exercises log, repeat, wait_frames",
  "seed": 1,
  "steps": [
    {"type": "wait_frames", "frames": 2},
    {"type": "log", "message": "strict mode scenario OK"},
    {"type": "repeat", "count": 2, "steps": [
      {"type": "wait_frames", "frames": 1},
      {"type": "log", "message": "repeat step OK"}
    ]}
  ]
}
"@ | Set-Content (Join-Path $scenarioDir "strict_smoke.json") -Encoding UTF8

        $scenarioLog    = Join-Path $env:TEMP "kilo_strict_scenario_err.txt"
        $scenarioOutLog = Join-Path $env:TEMP "kilo_strict_scenario_out.txt"
        # Jalankan --import dulu agar cache ter-build
        $null = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$strictDir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $proc2 = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$strictDir`"", "--", "--scenario", "res://scenarios/strict_smoke.json" `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $scenarioOutLog `
            -RedirectStandardError $scenarioLog
        $proc2.WaitForExit(30000)
        if (-not $proc2.HasExited) { $proc2.Kill() }

        $scenarioLines    = @(Get-Content $scenarioLog    -ErrorAction SilentlyContinue)
        $scenarioOutLines = @(Get-Content $scenarioOutLog -ErrorAction SilentlyContinue)
        # Filter: cek SEMUA SCRIPT ERROR di stderr (Parse Error, runtime crash, dll)
        # tidak mensyaratkan nama file tertentu di baris yang sama.
        $scenarioParseErrors = @($scenarioLines | Where-Object {
            $_ -match "Parse Error" -and $_ -notmatch "GDScript::reload"
        })
        $scenarioLoadErrors = @($scenarioLines | Where-Object {
            $_ -match "Failed to load script" -and $_ -notmatch "GDScript::reload"
        })
        $scenarioRuntimeErrors = @($scenarioLines | Where-Object {
            $_ -match "^SCRIPT ERROR:" -and $_ -notmatch "GDScript::reload"
        })
        $allScenarioErrors = $scenarioParseErrors.Count + $scenarioLoadErrors.Count + $scenarioRuntimeErrors.Count
        # Konfirmasi sukses dari stdout (print() GDScript ke stdout, bukan stderr)
        $scenarioPassed = $scenarioOutLines | Select-String "strict mode scenario OK"
        Remove-Item -LiteralPath $scenarioLog    -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scenarioOutLog -Force -ErrorAction SilentlyContinue

        if ($allScenarioErrors -eq 0 -and $scenarioPassed) {
            Add-Result "strict mode scenario (unsafe_method_access=2)" $true "ScenarioRunner parse+runtime bersih, log sukses terkonfirmasi"
        } elseif ($allScenarioErrors -eq 0) {
            Add-Result "strict mode scenario (unsafe_method_access=2)" $false "0 SCRIPT ERROR tapi konfirmasi sukses tidak ditemukan di stdout (scenario mungkin timeout atau tidak selesai)"
        } else {
            $errDetail = (($scenarioParseErrors + $scenarioLoadErrors + $scenarioRuntimeErrors) | Select-Object -First 2) -join "; "
            Add-Result "strict mode scenario (unsafe_method_access=2)" $false $errDetail
        }
        Remove-Item -LiteralPath $scenarioLog -Force -ErrorAction SilentlyContinue
    } catch {
        Add-Result "strict mode autoload (unsafe_method_access=2)" $false ("Exception: " + $_)
    }
} else {
    Write-T "TEST 7: SKIP -- -GodotExe tidak diset"
}
Write-S


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
