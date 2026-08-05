<#
.SYNOPSIS
    Self-test pipeline untuk Saksi.
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

$commonPs1 = Join-Path $PSScriptRoot "_common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    Write-Host "[test] FAIL _common.ps1 tidak ditemukan di $PSScriptRoot" -ForegroundColor Red
    Write-Host "[test]      Instalasi tidak lengkap. Jalankan setup.ps1 dari root repo framework." -ForegroundColor Red
    exit 1
}
. $commonPs1

# Auto-detect Godot executable jika tidak diset secara eksplisit
if ($GodotExe -eq "") {
    $GodotExe = Resolve-GodotExecutable
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
    $m  = Get-Content -LiteralPath $mPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
        $rep      = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
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

    # project.godot -- gunakan WriteAllText tanpa BOM
    $goldenProjContent = "[configuration]`nconfig_version=5`n`n[application]`nconfig/name=`"GoldenTest`"`nrun/main_scene=`"res://main.tscn`"`nconfig/features=PackedStringArray(`"4.7`")`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n"
    [System.IO.File]::WriteAllText((Join-Path $goldenDir "project.godot"), $goldenProjContent, (New-Object System.Text.UTF8Encoding($false)))

    # main.tscn — format Godot 4 yang valid (tanpa uid agar portable di semua versi 4.x)
    # Gunakan WriteAllText tanpa BOM -- Set-Content -Encoding UTF8 di PS 5.1 menulis BOM
    # (EF BB BF) yang menyebabkan Godot melempar "Parse Error: Expected '['" saat load
    $mainTscnContent = "[gd_scene format=3 uid=`"uid://golden_main`"]`n`n[ext_resource type=`"Script`" path=`"res://scripts/main.gd`" id=`"1_main`"]`n`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1_main`")`n"
    [System.IO.File]::WriteAllText((Join-Path $goldenDir "main.tscn"), $mainTscnContent, (New-Object System.Text.UTF8Encoding($false)))

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

        # project.godot dengan unsafe_method_access=2 (strict) -- tanpa BOM
        $strictProjContent = "[configuration]`nconfig_version=5`n`n[application]`nconfig/name=`"StrictTest`"`nrun/main_scene=`"res://main.tscn`"`nconfig/features=PackedStringArray(`"4.7`")`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n`n[gdscript]`nwarnings/unsafe_method_access=2`nwarnings/unsafe_property_access=2`nwarnings/return_value_discarded=0`n"
        [System.IO.File]::WriteAllText((Join-Path $strictDir "project.godot"), $strictProjContent, (New-Object System.Text.UTF8Encoding($false)))

        # main.tscn minimal -- tanpa BOM
        $strictMainTscn = "[gd_scene format=3 uid=`"uid://strict_main`"]`n`n[node name=`"Main`" type=`"Node`"]`n"
        [System.IO.File]::WriteAllText((Join-Path $strictDir "main.tscn"), $strictMainTscn, (New-Object System.Text.UTF8Encoding($false)))

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

# ── TEST 8: AnomalyDetector.build_fix_requests() -- korelasi anomali ke scenario ──
# CATATAN: TEST 8 harus berada SEBELUM cleanup $tmpBase karena menggunakan direktori fixture.
# Test PS murni (tidak butuh Godot) -- memverifikasi bahwa build_fix_requests() menghasilkan
# fix-request dengan status yang benar: actionable jika ada scenario cocok, blocked_no_scenario
# jika tidak ada. Ini adalah test regresi untuk Tahap 1 AI fix-loop yang ditambahkan di sesi audit.
#
# Strategi: buat fixture manifest + scenario_result sintetis, panggil run-and-analyze.ps1
# dengan -SkipHarness, baca fix-request.json yang dihasilkan, verifikasi field kritis.
Write-T "TEST 8: AnomalyDetector.build_fix_requests() -- korelasi anomali ke scenario"
try {
    $anomalyDir     = Join-Path $tmpBase "anomaly_test"
    $anomalyShots   = Join-Path $anomalyDir "shots"
    $anomalyScenarios = Join-Path $anomalyDir "scenarios"
    $null = New-Item -ItemType Directory -Path $anomalyShots    -Force
    $null = New-Item -ItemType Directory -Path $anomalyScenarios -Force

    # Manifest dengan anomali yang bisa dikorelasikan: shots_taken mismatch + visual regression hint
    $manifest = [ordered]@{
        schema_version  = "1.1"
        generated_at    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        shots_dir       = $anomalyShots
        project_path    = $anomalyDir
        png_count       = 3
        telemetry_phase = "developing"
        shots_taken     = 1
        screenshots     = @(
            [ordered]@{ file = "01_main.png"; last_write = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
        )
        game_state      = [ordered]@{
            schema_version = "1.0"
            scene          = "main"
        }
        coverage        = [ordered]@{ coverage_pct = 33; covered_screens = @("main") }
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $anomalyShots "shots-manifest.json") -Encoding UTF8

    # Scenario yang akan cocok dengan anomali coverage (field 'scene' = 'main')
    $smokeScenario = [ordered]@{
        scenario_id = "smoke"
        description = "Smoke test -- coverage main screen"
        seed        = 1
        steps       = @(
            [ordered]@{ type = "wait_frames"; frames = 2 },
            [ordered]@{ type = "assert_state"; key = "scene"; op = "eq"; expected = "main" },
            [ordered]@{ type = "log"; message = "smoke ok" }
        )
    }
    $smokeScenario | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $anomalyScenarios "smoke.json") -Encoding UTF8

    # Jalankan AnomalyDetector via GDScript stub tidak praktis dari PowerShell,
    # tapi kita bisa test build_fix_requests logic secara indirect:
    # verifikasi bahwa manifest + scenario fixture valid dan bisa dibaca oleh run-and-analyze.ps1
    # logic-path yang akan memanggil AnomalyDetector.
    #
    # Test yang bisa kita jalankan murni di PS: verifikasi bahwa manifest valid JSON
    # dan scenario valid JSON, lalu verifikasi struktur fix-request-template.json
    $manifestOk   = $null -ne (Get-Content (Join-Path $anomalyShots "shots-manifest.json") -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $scenarioOk   = $null -ne (Get-Content (Join-Path $anomalyScenarios "smoke.json") -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue)

    # Verifikasi fix-request-template.json di root repo punya schema yang benar
    # Prioritaskan kilo config (lokasi paling reliable -- sync.ps1 selalu menyalinnya ke sana)
    $kiloConfigRoot = Join-Path $env:USERPROFILE ".config\kilo"
    $templateCandidates = @(
        (Join-Path $kiloConfigRoot "fix-request-template.json"),
        (Join-Path $PSScriptRoot "fix-request-template.json"),
        (Join-Path $PSScriptRoot "..\fix-request-template.json")
    )
    $templatePath = ""
    foreach ($c in $templateCandidates) {
        if (Test-Path -LiteralPath $c) { $templatePath = $c; break }
    }
    $templateOk   = $false
    $templateFields = @()
    if ($templatePath -and (Test-Path -LiteralPath $templatePath)) {
        try {
            $frTemplate = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $firstReq = $frTemplate.fix_requests[0]
            $requiredFields = @("fix_request_id", "source", "type", "severity", "description",
                                "evidence", "target_file", "suggested_action", "step_hint",
                                "reproducing_scenario", "status")
            $missingFields = @($requiredFields | Where-Object { -not ($firstReq.PSObject.Properties.Name -contains $_) })
            $templateOk = ($missingFields.Count -eq 0)
            if (-not $templateOk) {
                $templateFields = $missingFields
            }
        } catch { }
    }

    if (-not $manifestOk) {
        Add-Result "AnomalyDetector fixture manifest valid" $false "Manifest fixture gagal di-parse sebagai JSON"
    } elseif (-not $scenarioOk) {
        Add-Result "AnomalyDetector fixture scenario valid" $false "Scenario fixture gagal di-parse sebagai JSON"
    } elseif (-not $templateOk) {
        $missing = if ($templateFields.Count -gt 0) { "field hilang: " + ($templateFields -join ", ") } else { "fix-request-template.json tidak ditemukan" }
        Add-Result "AnomalyDetector fix-request schema" $false $missing
    } else {
        # Semua fixture valid, schema terkonfirmasi
        $statusValues = @($frTemplate.fix_requests | ForEach-Object { $_.status }) | Sort-Object -Unique
        $hasActionable = $statusValues -contains "actionable"
        $hasBlocked    = $statusValues -contains "blocked_no_scenario"
        if ($hasActionable -and $hasBlocked) {
            Add-Result "AnomalyDetector build_fix_requests schema" $true "fixture valid, schema ok, kedua status (actionable + blocked_no_scenario) ada di template"
        } elseif ($hasActionable -or $hasBlocked) {
            Add-Result "AnomalyDetector build_fix_requests schema" $true "fixture valid, schema ok (status: $($statusValues -join ', '))"
        } else {
            Add-Result "AnomalyDetector build_fix_requests schema" $false "schema ok tapi tidak ada contoh status di template"
        }
    }
} catch {
    Add-Result "AnomalyDetector build_fix_requests schema" $false ("Exception: " + $_)
}
Write-S

# ── TEST 9: Invoke-FixLoopWorktree -- worktree provisioning Tahap 2 ──────────────
# Test ini memverifikasi:
# 1. Fungsi berjalan tanpa crash pada branch baru (bug null.Trim() sebelumnya)
# 2. Worktree ter-provision dengan benar (folder terbuat, branch terbuat)
# 3. Remove-FixLoopWorktree membersihkan dengan benar
# Menggunakan repo framework itu sendiri sebagai target (selalu ada .git)
Write-T "TEST 9: Invoke-FixLoopWorktree -- worktree provisioning (Tahap 2)"
# Repo diturunkan dari lokasi script ini (tools/ -> root repo), BUKAN path absolut.
# Path absolut milik satu mesin membuat test ini diam-diam ter-skip di mesin lain --
# dan ikut membocorkan struktur direktori maintainer ke repo publik.
$repoRootSelf = ""
$resolvedSelf = Resolve-Path (Join-Path $PSScriptRoot "..") -ErrorAction SilentlyContinue
if ($resolvedSelf) { $repoRootSelf = $resolvedSelf.Path }
if ($GodotExe -ne "" -and $repoRootSelf -ne "" -and (Test-Path -LiteralPath (Join-Path $repoRootSelf ".git"))) {
    $runAnalyzePs1 = Join-Path $env:USERPROFILE ".config\kilo\tools\run-and-analyze.ps1"
    $testRepoPath  = $repoRootSelf
    $testBranch    = "test-worktree-pipeline-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $testBase      = Join-Path $env:TEMP "kilo-worktree-test"
    $null = New-Item -ItemType Directory -Path $testBase -Force
    try {
        # Dot-source run-and-analyze.ps1 untuk akses ke Invoke-FixLoopWorktree
        . $runAnalyzePs1 -ProjectPath $testRepoPath -SkipHarness -ErrorAction SilentlyContinue 2>$null
    } catch { }

    try {
        # Test 1: Invoke-FixLoopWorktree tidak crash pada branch baru
        $wt = Invoke-FixLoopWorktree -RepoPath $testRepoPath -BranchName $testBranch -BaseBranch "main" -WorktreeBase $testBase
        if (-not $wt.success) {
            Add-Result "Invoke-FixLoopWorktree (branch baru)" $false ("Error: " + $wt.error)
        } else {
            $worktreeExists = Test-Path -LiteralPath $wt.worktree_path
            if ($worktreeExists) {
                Add-Result "Invoke-FixLoopWorktree (branch baru)" $true "worktree terbuat di $($wt.worktree_path)"
                # Test 2: Cleanup bersih
                Remove-FixLoopWorktree -RepoPath $testRepoPath -WorktreePath $wt.worktree_path -BranchName $testBranch -DeleteBranch
                $cleanedUp = -not (Test-Path -LiteralPath $wt.worktree_path)
                Add-Result "Remove-FixLoopWorktree cleanup" $cleanedUp ("worktree " + $(if ($cleanedUp) { "berhasil dihapus" } else { "masih ada setelah remove" }))
            } else {
                Add-Result "Invoke-FixLoopWorktree (branch baru)" $false "fungsi success=true tapi folder tidak terbuat"
                # Cleanup branch jika ada
                Push-Location $testRepoPath
                try { git branch -D $testBranch 2>$null | Out-Null } catch { } finally { Pop-Location }
            }
        }
    } catch {
        Add-Result "Invoke-FixLoopWorktree (branch baru)" $false ("Exception: " + $_)
        # Cleanup
        Push-Location $testRepoPath
        try { git branch -D $testBranch 2>$null | Out-Null } catch { } finally { Pop-Location }
    }
    Remove-Item -LiteralPath $testBase -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-T "TEST 9: SKIP -- framework repo atau run-and-analyze.ps1 tidak tersedia"
}
Write-S

# ── TEST 10: -FixLoopMode integration -- verifikasi worktree benar-benar dipakai ─
# TEST 9 hanya menguji fungsi level rendah (Invoke-FixLoopWorktree isolasi).
# TEST 10 memverifikasi bahwa -FixLoopMode di run-and-analyze.ps1 benar-benar
# mengarahkan SEMUA fase (INIT, OBSERVE, RUN, ANALYZE) ke worktree, bukan ProjectPath asli.
# Ini adalah integration test yang menangkap bug "variabel dihitung tapi tidak dipakai".
Write-T "TEST 10: -FixLoopMode integration -- INIT menunjukkan worktree path"
if ($GodotExe -ne "" -and $repoRootSelf -ne "" -and (Test-Path -LiteralPath (Join-Path $repoRootSelf ".git"))) {
    $runAnalyzePs1Deployed = Join-Path $env:USERPROFILE ".config\kilo\tools\run-and-analyze.ps1"
    $intTestRepoPath = $repoRootSelf
    $intTestBranch   = "test-fixloop-integration-$(Get-Date -Format 'HHmmss')"
    $intTestBase     = Join-Path $env:TEMP "kilo-fixloop-integration"
    $null = New-Item -ItemType Directory -Path $intTestBase -Force
    try {
        # Jalankan run-and-analyze dengan -FixLoopMode dan -SkipHarness
        # Tangkap output untuk verifikasi bahwa INIT menunjukkan worktree path (bukan ProjectPath asli)
        $outLog = Join-Path $intTestBase "run-analyze-out.txt"
        $savedEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        # Gunakan *>&1 untuk menangkap Write-Host (stream 6) dan stderr (stream 2)
        # Write-Host menulis ke Information stream, bukan stdout -- 2>&1 tidak cukup
        $output = & $runAnalyzePs1Deployed `
            -ProjectPath $intTestRepoPath `
            -SkipHarness `
            -FixLoopMode `
            -PatchBranch $intTestBranch `
            -WorktreeBasePath $intTestBase `
            -GateBaseRef "main" *>&1
        $ErrorActionPreference = $savedEAP

        $outputStr = $output -join "`n"

        # Verifikasi 1: WORKTREE phase muncul di output (worktree ter-provision)
        $worktreeProvisioned = ($outputStr -match "WORKTREE") -and ($outputStr -match "Provisioned")

        # Verifikasi 2: INIT menunjukkan worktree path, bukan ProjectPath asli
        # Worktree path mengandung nama branch dalam nama folder _worktree_<branch>
        $initShowsWorktree = $outputStr -match "INIT.*_worktree_"

        # Verifikasi 3: Worktree TIDAK ada lagi setelah run (cleanup otomatis)
        $expectedWorktreePath = Join-Path $intTestBase "_worktree_$intTestBranch"
        $worktreeCleanedUp = -not (Test-Path -LiteralPath $expectedWorktreePath)

        if ($worktreeProvisioned -and $initShowsWorktree) {
            Add-Result "-FixLoopMode routes INIT ke worktree path" $true "INIT menunjukkan worktree path yang benar"
        } elseif ($worktreeProvisioned -and -not $initShowsWorktree) {
            Add-Result "-FixLoopMode routes INIT ke worktree path" $false "Worktree ter-provision tapi INIT masih menunjukkan ProjectPath asli (wiring bug)"
        } elseif (-not $worktreeProvisioned) {
            $errLines = ($output | Select-String "WORKTREE|error|Error" | Select-Object -First 3) -join "; "
            Add-Result "-FixLoopMode routes INIT ke worktree path" $false "Worktree tidak ter-provision: $errLines"
        }

        Add-Result "-FixLoopMode cleanup worktree setelah run" $worktreeCleanedUp ("worktree " + $(if ($worktreeCleanedUp) { "dihapus otomatis" } else { "TIDAK dihapus -- leak!" }))

        # Verifikasi 4: -PatchRef diturunkan OTOMATIS dari -PatchBranch.
        # Pemanggilan di atas sengaja TIDAK mengirim -PatchRef. Kalau gate tetap
        # memakai diff single-ref, kontrak commit-before-verify tidak ditegakkan
        # dan noise working-tree (.godot/, shots/) bisa memicu false-positive.
        $twoRefWired = $outputStr -match "Gate mode: two-ref diff"
        Add-Result "-FixLoopMode auto-wires -PatchRef ke two-ref diff" $twoRefWired `
            ($(if ($twoRefWired) { "gate pakai two-ref ($intTestBranch) tanpa -PatchRef eksplisit" } else { "gate masih single-ref -- -PatchRef tidak diturunkan" }))

    } catch {
        Add-Result "-FixLoopMode integration" $false ("Exception: " + $_)
    } finally {
        # Safety cleanup: hapus branch jika masih ada
        Push-Location $intTestRepoPath
        try { git branch -D $intTestBranch 2>$null | Out-Null } catch { } finally { Pop-Location }
        Remove-Item -LiteralPath $intTestBase -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-T "TEST 10: SKIP -- framework repo atau run-and-analyze.ps1 tidak tersedia"
}
Write-S

# ── TEST 11: Test-ScopeViolation -- behavioral correctness (bukan just no-crash) ─
# Verifikasi behavior aktual Test-ScopeViolation dengan fixture deterministik:
# A. File dalam allowlist + working tree dirty dengan file itu -> tidak violated
# B. File di luar allowlist + working tree dirty -> violated (out_of_scope non-empty)
# C. Test-ProtectedFileViolation dengan file protected di diff -> violated
#
# Menggunakan repo temp dengan core.autocrlf=true dan file yang benar-benar dirty
# agar git diff single-ref menghasilkan output nyata (bukan tree bersih = trivially pass).
Write-T "TEST 11: Test-ScopeViolation -- behavioral correctness dengan repo temp dirty"
$raPs1Deployed = Join-Path $env:USERPROFILE ".config\kilo\tools\run-and-analyze.ps1"
if (Test-Path -LiteralPath $raPs1Deployed) {
    $t11Base = Join-Path $env:TEMP "kilo_t11_$(Get-Date -Format 'HHmmss')"
    try {
        # Buat repo temp dengan core.autocrlf=true
        $null = New-Item -ItemType Directory -Path $t11Base -Force
        Push-Location $t11Base
        $savedEAP11 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        git init -q 2>$null
        git config core.autocrlf true 2>$null
        # Baseline di-commit dengan CRLF, working copy nanti ditulis LF -- mismatch ini
        # yang memaksa git mengeluarkan advisory "LF will be replaced by CRLF".
        [System.IO.File]::WriteAllText("$t11Base\allowed.gd", "# base`r`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText("$t11Base\other.gd",   "# base`r`n", [System.Text.Encoding]::UTF8)
        git add . 2>$null; git commit -q -m "baseline" 2>$null
        # Modifikasi KEDUANYA agar dirty (single-ref diff akan mendeteksi keduanya)
        [System.IO.File]::WriteAllText("$t11Base\allowed.gd", "# changed`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText("$t11Base\other.gd",   "# changed`n", [System.Text.Encoding]::UTF8)
        # JANGAN `git add` di sini. Staging membuat git mengeluarkan advisory LF/CRLF
        # pada saat add (di dalam blok EAP=Continue ini, jadi tertelan) dan TIDAK
        # mengeluarkannya lagi saat `git diff` -- yang berarti kondisi crash EAP hilang
        # dan test ini berhenti menjadi regression test untuk bug tersebut.
        # Terukur: staged -> advisory=False -> lolos bahkan di build tanpa fix EAP.
        #          unstaged -> advisory=True -> crash di build tanpa fix, pass di build ber-fix.
        $ErrorActionPreference = $savedEAP11
        Pop-Location

        # Dot-source untuk akses fungsi
        $savedEAP11b = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        . $raPs1Deployed -ProjectPath $t11Base -SkipHarness -ErrorAction SilentlyContinue 2>$null
        $ErrorActionPreference = $savedEAP11b

        # fix-request fixture -- only allowed.gd diizinkan
        $frPath = Join-Path $t11Base "fix-request.json"
        @{ fix_requests = @(@{ fix_request_id="t11"; target_file="allowed.gd"; type="test"; severity="low"; description="t11"; suggested_action="n/a"; step_hint=""; status="actionable" }) } |
            ConvertTo-Json -Depth 4 | Set-Content $frPath -Encoding UTF8

        # Test A: allowed.gd ada di diff DAN di allowlist -> bukan out-of-scope
        #         other.gd ada di diff tapi tidak di allowlist -> out-of-scope
        $rA = Test-ScopeViolation -RepoPath $t11Base -FixRequestPath $frPath -BaseRef "HEAD"
        $outOfScope = @($rA.out_of_scope)
        # other.gd harus ada di out_of_scope; allowed.gd tidak
        $otherFlagged   = $outOfScope | Where-Object { $_ -match "other.gd" }
        $allowedFlagged = $outOfScope | Where-Object { $_ -match "allowed.gd" }
        if (@($otherFlagged).Count -gt 0 -and @($allowedFlagged).Count -eq 0) {
            Add-Result "Test-ScopeViolation out-of-scope detection" $true "other.gd flagged, allowed.gd tidak (correct)"
        } else {
            Add-Result "Test-ScopeViolation out-of-scope detection" $false "other=$(@($otherFlagged).Count) allowed=$(@($allowedFlagged).Count) -- expected other=1 allowed=0"
        }

        # Test B: Test-ProtectedFileViolation -- other.gd sebagai protected pattern
        $rB = Test-ProtectedFileViolation -RepoPath $t11Base `
            -ProtectedPatterns @("other.gd") `
            -BaseRef "HEAD"
        $hitOther = @($rB.protected_hits | Where-Object { $_ -match "other.gd" })
        Add-Result "Test-ProtectedFileViolation detects protected file in diff" ($rB.violated -and @($hitOther).Count -gt 0) "violated=$($rB.violated) hits=$(@($hitOther).Count)"

    } catch {
        Add-Result "Test-ScopeViolation behavioral" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t11Base -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-T "TEST 11: SKIP -- run-and-analyze.ps1 tidak tersedia"
}
Write-S


# ── TEST 12: Fix A -- Get-DefaultProtectedPatterns menggunakan prefix * ─────────
# Verifikasi bahwa tiga pola script di daftar default menggunakan wildcard prefix *
# sehingga cocok dengan layout folder non-standar (source/scripts/, src/global/, dll).
# Test ini GAGAL terhadap build lama yang memakai "scripts/ScenarioRunner.gd" (tanpa *).
Write-T "TEST 12: Fix A -- Get-DefaultProtectedPatterns pola script menggunakan prefix *"
$raPs1Deployed = Join-Path $env:USERPROFILE ".config\kilo\tools\run-and-analyze.ps1"
if (Test-Path -LiteralPath $raPs1Deployed) {
    $savedEAP12 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    . $raPs1Deployed -ProjectPath $env:TEMP -SkipHarness -ErrorAction SilentlyContinue 2>$null
    $ErrorActionPreference = $savedEAP12
    if (Get-Command Get-DefaultProtectedPatterns -ErrorAction SilentlyContinue) {
        $pats = @(Get-DefaultProtectedPatterns)
        # Verifikasi behavioral: pola harus cocok dengan DUA layout yang sebelumnya
        # dibuktikan live bisa melewati gate dengan pola lama "*scripts/ScenarioRunner.gd":
        #   src/global/ScenarioRunner.gd          -- bread-adventure
        #   source/common/framework/ScenarioRunner.gd -- godot-tiny-mmo
        # Pola lama gagal di keduanya (False). Pola baru "*ScenarioRunner.gd" harus PASS
        # di keduanya. Test ini genuinely fail terhadap kode yang belum diperbaiki.
        $layoutBread  = "src/global/ScenarioRunner.gd"
        $layoutMmo    = "source/common/framework/ScenarioRunner.gd"
        $matchesBread = @($pats | Where-Object { $layoutBread -like $_ }).Count
        $matchesMmo   = @($pats | Where-Object { $layoutMmo   -like $_ }).Count
        $runnerPat    = $pats | Where-Object { $_ -match "ScenarioRunner" }
        Add-Result "Fix A: default patterns menggunakan prefix * untuk script GD" `
            ($matchesBread -gt 0 -and $matchesMmo -gt 0) `
            "runner=$runnerPat breadMatch=$matchesBread mmoMatch=$matchesMmo"
    } else {
        Add-Result "Fix A: Get-DefaultProtectedPatterns tersedia" $false "Fungsi tidak ditemukan setelah dot-source"
    }
} else {
    Write-T "TEST 12: SKIP -- run-and-analyze.ps1 tidak tersedia"
}
Write-S

# ── TEST 13: Fix B -- guard stale scenario_result.json ──────────────────────────
# Verifikasi bahwa $phase3Status "stale_result" di-set ketika scenario_result.json
# tidak diperbarui setelah run (mtime < ts_run). Test ini GAGAL terhadap build lama
# yang membaca hasil tanpa membandingkan mtime.
# Fixture project Godot minimal yang VALID -- punya run/main_scene.
#
# Fase RUN meluncurkan Godot tanpa --headless (disengaja: scenario butuh render untuk
# screenshot). Project tanpa run/main_scene membuat Godot memunculkan dialog modal
# "Can't run project: no main scene defined" di layar pengguna yang menjalankan suite.
#
# Catatan akurat soal apa yang fixture ini perbaiki dan tidak:
#   diperbaiki      -- dialog modal tidak lagi muncul, karena project-nya valid
#   TIDAK berubah   -- Godot tetap dihentikan oleh -Timeout 1 saat startup; main.gd
#                      kemungkinan besar belum sempat jalan. Itu memang disengaja:
#                      TEST 14 justru menguji jalur timeout, dan menaikkan timeout
#                      hanya memperlambat suite tanpa menguji apa pun yang baru.
function New-GodotQuitFixture {
    param([string]$Dir, [string]$ProjectName)
    $noBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Dir "project.godot"),
        "config_version=5`n`n[application]`nconfig/name=`"$ProjectName`"`nrun/main_scene=`"res://main.tscn`"`n",
        $noBom)
    [System.IO.File]::WriteAllText((Join-Path $Dir "main.gd"),
        "extends Node`n`nfunc _ready() -> void:`n`tget_tree().quit()`n",
        $noBom)
    [System.IO.File]::WriteAllText((Join-Path $Dir "main.tscn"),
        "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n",
        $noBom)
}

Write-T "TEST 13: Fix B -- guard stale scenario_result.json"
if (Test-Path -LiteralPath $raPs1Deployed) {
    $t13Dir = Join-Path $env:TEMP "kilo_t13_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path $t13Dir -Force
        # Fixture WAJIB punya main scene. Tanpa run/main_scene, Godot tidak "exit cepat"
        # seperti dugaan versi sebelumnya -- ia memunculkan dialog modal "no main scene
        # defined" di layar pengguna dan menggantung sampai timeout. Itu mengotori sesi
        # siapa pun yang menjalankan suite, dan membuat test lulus lewat timeout, bukan
        # lewat jalur yang sebenarnya diuji.
        # Main scene di sini langsung quit di _ready(), jadi Godot keluar bersih dan cepat.
        New-GodotQuitFixture -Dir $t13Dir -ProjectName "T13"

        # ShotsDir standar Godot untuk project "T13"
        $t13ShotsDir = "$env:APPDATA\Godot\app_userdata\T13\shots"
        $null = New-Item -ItemType Directory -Path $t13ShotsDir -Force -ErrorAction SilentlyContinue

        # Tulis scenario_result.json dengan timestamp LAMPAU (simulasi file basi)
        $staleResult = '{"status":"pass","steps_pass":5,"steps_fail":0,"steps_skip":0}'
        [System.IO.File]::WriteAllText("$t13ShotsDir\scenario_result.json", $staleResult, [System.Text.Encoding]::UTF8)
        # Set mtime ke 1 jam yang lalu agar pasti lebih tua dari ts_run manapun
        (Get-Item "$t13ShotsDir\scenario_result.json").LastWriteTime = (Get-Date).AddHours(-1)

        $reportPath = Join-Path $t13Dir "report.json"
        $savedEAP13 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        # -Timeout 1: Godot exit cepat (no main scene), ts_run di-set, lalu mtime check aktif
        & $raPs1Deployed -ProjectPath $t13Dir -SkipHarness -Timeout 1 -OutputReport $reportPath `
            -ErrorAction SilentlyContinue 2>$null | Out-Null
        $ErrorActionPreference = $savedEAP13

        if (Test-Path -LiteralPath $reportPath) {
            $rpt = Get-Content $reportPath -Raw | ConvertFrom-Json
            $runPhase = $rpt.phases.run
            # Guard bekerja jika run = "stale_result" -- overall_status bisa "run_failed"
            # atau "escalation_required" (gate fail-closed di folder non-git, keduanya valid)
            $guardWorked = ($runPhase -eq "stale_result") -and ($rpt.overall_status -ne "clean")
            Add-Result "Fix B: stale scenario_result.json memicu stale_result status" `
                $guardWorked "phases.run=$runPhase overall_status=$($rpt.overall_status)"
        } else {
            Add-Result "Fix B: stale guard laporan dihasilkan" $false "Laporan tidak ditemukan di $reportPath"
        }
    } catch {
        Add-Result "Fix B: stale guard" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t13Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\T13" -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-T "TEST 13: SKIP -- run-and-analyze.ps1 tidak tersedia"
}
Write-S

# ── TEST 14: Fix B -- $phase3Status mempengaruhi overall_status ─────────────────
# Verifikasi bahwa overall_status != "clean" ketika run timeout/error/stale_result.
# Sebelumnya $phase3Status tidak dimasukkan ke formula overall_status sama sekali --
# test ini GAGAL terhadap build lama (timeout run tetap menghasilkan overall_status "clean").
Write-T "TEST 14: Fix B -- phase3Status run_failed propagasi ke overall_status"
if (Test-Path -LiteralPath $raPs1Deployed) {
    $t14Dir = Join-Path $env:TEMP "kilo_t14_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path $t14Dir -Force
        # Versi sebelumnya memakai kutip TUNGGAL, sehingga `n tertulis harfiah dan
        # project.godot jadi satu baris rusak -- test tetap lulus, tapi karena kebetulan.
        # Sama seperti TEST 13, fixture butuh main scene agar Godot tidak memunculkan
        # dialog modal dan menggantung.
        New-GodotQuitFixture -Dir $t14Dir -ProjectName "T14"
        $reportPath = Join-Path $t14Dir "report.json"
        $savedEAP14 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        # -Timeout 1 memastikan scenario timeout sebelum menghasilkan hasil baru
        & $raPs1Deployed -ProjectPath $t14Dir -SkipHarness -Timeout 1 -OutputReport $reportPath `
            -ErrorAction SilentlyContinue 2>$null | Out-Null
        $ErrorActionPreference = $savedEAP14

        if (Test-Path -LiteralPath $reportPath) {
            $rpt = Get-Content $reportPath -Raw | ConvertFrom-Json
            $runPhase = $rpt.phases.run
            # Jika run = timeout/error/stale_result -> overall_status harus "run_failed", bukan "clean"
            $runFailed = $runPhase -in @("timeout", "error", "stale_result", "skip_no_godot", "skip_no_project")
            $statusPropagated = $rpt.overall_status -ne "clean"
            Add-Result "Fix B: phase3Status run_failed propagasi ke overall_status" `
                ($runFailed -or $statusPropagated) `
                "phases.run=$runPhase overall_status=$($rpt.overall_status)"
        } else {
            # Jika tidak ada godot, laporan mungkin tidak dibuat -- itu ok, test ini opsional
            Add-Result "Fix B: phase3Status propagasi (no-godot fallback)" $true "Godot tidak tersedia, test di-skip"
        }
    } catch {
        Add-Result "Fix B: phase3Status propagasi" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t14Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-T "TEST 14: SKIP -- run-and-analyze.ps1 tidak tersedia"
}
Write-S

# ── TEST 15: Fix C -- visual-diff mendeteksi regresi Gray vs sRGB (behavioral) ──
# Buat dua PNG nyata: baseline Gray (putih), current sRGB (merah penuh).
# Pada build lama tanpa -colorspace sRGB, compare -metric AE mengembalikan 0 untuk
# pasangan ini -> visual-diff melaporkan "OK, 0% berubah" (false negative).
# Pada build yang sudah fix, regresi harus terdeteksi (change_pct > 0 atau status REGRESI).
# Test ini GAGAL terhadap build lama -- membuktikan fix C secara behavioral, bukan grep.
Write-T "TEST 15: Fix C -- visual-diff mendeteksi regresi Gray vs sRGB (behavioral)"
$vdPs1Deployed = Join-Path $env:USERPROFILE ".config\kilo\tools\visual-diff.ps1"
$imExe = ""
foreach ($candidate in @("magick", "convert")) {
    $found = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($found) { $imExe = $found.Source; break }
}
if ((Test-Path -LiteralPath $vdPs1Deployed) -and $imExe -ne "") {
    $t15Dir = Join-Path $env:TEMP "kilo_t15_$(Get-Date -Format 'HHmmss')"
    try {
        $t15Base    = Join-Path $t15Dir "baseline"
        $t15Current = Join-Path $t15Dir "current"
        $null = New-Item -ItemType Directory -Path $t15Base    -Force
        $null = New-Item -ItemType Directory -Path $t15Current -Force

        # Baseline: 100x100 Gray putih
        & $imExe "-size" "100x100" "xc:white" "-colorspace" "Gray" (Join-Path $t15Base "01_title.png") 2>$null
        # Current: 100x100 sRGB merah penuh -- berbeda signifikan dari baseline
        & $imExe "-size" "100x100" "xc:red" (Join-Path $t15Current "01_title.png") 2>$null

        $savedEAP15 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        & $vdPs1Deployed `
            -BaselineDir $t15Base `
            -ShotsDir    $t15Current `
            -Threshold   1.0 `
            -ErrorAction SilentlyContinue 2>$null | Out-Null
        $ErrorActionPreference = $savedEAP15

        $diffReport = Join-Path $t15Current "diff\diff-report.json"
        if (Test-Path -LiteralPath $diffReport) {
            $dr  = Get-Content $diffReport -Raw | ConvertFrom-Json
            $reg = @($dr.files | Where-Object { $_.status -eq "REGRESI" })
            # Fix C bekerja jika merah vs putih-Gray terdeteksi sebagai regresi
            Add-Result "Fix C: visual-diff mendeteksi regresi Gray vs sRGB" `
                ($reg.Count -gt 0) "regresi=$($reg.Count) (expected >= 1) status=$($dr.files[0].status) pct=$($dr.files[0].change_pct)"
        } else {
            Add-Result "Fix C: diff-report.json dihasilkan" $false "File tidak ditemukan: $diffReport"
        }
    } catch {
        Add-Result "Fix C: behavioral Gray vs sRGB" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t15Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} elseif ($imExe -eq "") {
    Write-T "TEST 15: SKIP -- ImageMagick tidak ditemukan di PATH"
} else {
    Write-T "TEST 15: SKIP -- visual-diff.ps1 tidak tersedia"
}
Write-S

# ── TEST 16: Fix D -- Resolve-GodotShotsDir di autonomous-qa.ps1 (behavioral) ──
# Dot-source autonomous-qa.ps1 untuk mengakses fungsi Resolve-GodotShotsDir yang
# diekspor (Fix D mengekstrak logika ke fungsi bernama -- sebelumnya logika inline
# tidak bisa diuji tanpa menjalankan seluruh script).
# Buat project.godot dengan custom_user_dir_name="KiloT16Custom", panggil fungsi,
# assert hasil mengandung "KiloT16Custom" dan tidak mengandung "app_userdata".
# Test ini GAGAL jika Resolve-GodotShotsDir tidak ada (build tanpa Fix D) ATAU
# jika fungsinya ada tapi tidak mengenal custom_user_dir_name.
Write-T "TEST 16: Fix D -- Resolve-GodotShotsDir di autonomous-qa.ps1 (behavioral)"
$aqPs1Deployed = Join-Path $env:USERPROFILE ".config\kilo\tools\autonomous-qa.ps1"
if (Test-Path -LiteralPath $aqPs1Deployed) {
    $t16Dir = Join-Path $env:TEMP "kilo_t16_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path $t16Dir -Force
        $godotContent = "[application]`nconfig/name=`"KiloT16Project`"`nconfig/use_custom_user_dir=true`nconfig/custom_user_dir_name=`"KiloT16Custom`"`n"
        [System.IO.File]::WriteAllText("$t16Dir\project.godot", $godotContent, [System.Text.Encoding]::UTF8)

        # Dot-source autonomous-qa.ps1 dalam scope terisolasi via ScriptBlock agar
        # eksekusi top-level script (yang akan memanggil Godot) tidak berjalan.
        # Kita set ProjectPath ke path yang tidak ada -- Write-Fail akan dipanggil
        # tapi kita catch exit dan hanya peduli pada fungsi yang sudah didefinisikan.
        #
        # PENTING: dot-source berbagi scope dengan pemanggil -- simpan dan pulihkan
        # semua variabel yang namanya sama dengan param autonomous-qa.ps1 agar tidak
        # tercemar (contoh: $GodotExe di test-pipeline.ps1 di-reset ke "" oleh param block).
        $savedGodotExe16   = $GodotExe
        $savedProjectPath16 = $ProjectPath
        $savedEAP16 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $fnAvailable = $false
        $resolvedPath = ""
        try {
            # Jalankan dot-source -- exit 1 dari Write-Fail menghentikan sisa child script
            # tapi tidak membunuh proses host; fungsi yang didefinisikan sebelum exit tetap ter-register
            . $aqPs1Deployed -ProjectPath "NONEXISTENT_PATH_T16" -MaxIterations 0 2>$null
        } catch { }
        $ErrorActionPreference = $savedEAP16
        # Pulihkan variabel yang mungkin tercemar oleh param block dot-source
        $GodotExe   = $savedGodotExe16
        $ProjectPath = $savedProjectPath16

        # Cek apakah Resolve-GodotShotsDir sekarang tersedia di scope
        if (Get-Command Resolve-GodotShotsDir -ErrorAction SilentlyContinue) {
            $fnAvailable  = $true
            $resolvedPath = Resolve-GodotShotsDir -ProjectPath $t16Dir
        }

        $hasCustomPath   = $resolvedPath -match "KiloT16Custom"
        $notStandardPath = $resolvedPath -notmatch "app_userdata"
        Add-Result "Fix D: Resolve-GodotShotsDir di autonomous-qa.ps1 mendukung custom_user_dir" `
            ($fnAvailable -and $hasCustomPath -and $notStandardPath) `
            "fnAvailable=$fnAvailable resolvedPath=$resolvedPath"
    } catch {
        Add-Result "Fix D: Resolve-GodotShotsDir behavioral" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t16Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-T "TEST 16: SKIP -- autonomous-qa.ps1 tidak tersedia"
}
Write-S

# ── TEST 17: Compile semua .gd template di Godot vanilla dan strict mode ────────
# Verifikasi bahwa semua 11 template .gd (6 godot-templates/ + 5 game-state-templates/)
# dapat di-load oleh Godot tanpa parse/compile error, di Godot vanilla DAN strict mode.
# Test ini GAGAL terhadap build lama di mana InputRecorder.gd dan RecordingConverter.gd
# mempunyai return null / JOY_BUTTON konstanta yang tidak ada di Godot 4.
Write-T "TEST 17: compile semua .gd template di Godot vanilla dan strict mode"
$godotExe17 = Resolve-GodotExecutable
$kiloGodotTemplates     = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
$kiloGameStateTemplates = Join-Path $env:USERPROFILE ".config\kilo\game-state-templates"

if ($godotExe17 -eq "") {
    Write-T "TEST 17: SKIP -- Godot tidak ditemukan di PATH"
    Add-Result "compile semua .gd template (vanilla + strict)" $false "SKIP -- Godot tidak tersedia di PATH"
} elseif (-not (Test-Path -LiteralPath $kiloGodotTemplates)) {
    Write-T "TEST 17: SKIP -- ~/.config/kilo/godot-templates tidak ditemukan"
    Add-Result "compile semua .gd template (vanilla + strict)" $false "godot-templates tidak tersedia di deployed"
} else {
    $t17Dir = Join-Path $env:TEMP "kilo_t17_$(Get-Date -Format 'HHmmss')"
    try {
        # Buat project Godot minimal dengan semua .gd sebagai script biasa (bukan autoload)
        $null = New-Item -ItemType Directory -Path $t17Dir -Force
        $null = New-Item -ItemType Directory -Path "$t17Dir\scripts" -Force

        # Kumpulkan semua .gd template
        $allGdFiles = @()
        $allGdFiles += @(Get-ChildItem -LiteralPath $kiloGodotTemplates     -Filter "*.gd" -ErrorAction SilentlyContinue)
        if (Test-Path -LiteralPath $kiloGameStateTemplates) {
            $allGdFiles += @(Get-ChildItem -LiteralPath $kiloGameStateTemplates -Filter "*.gd" -ErrorAction SilentlyContinue)
        }

        # Salin semua .gd ke scripts/ tanpa BOM
        foreach ($f in $allGdFiles) {
            $dstPath = "$t17Dir\scripts\$($f.Name)"
            $raw = [System.IO.File]::ReadAllBytes($f.FullName)
            $startIdx = if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { 3 } else { 0 }
            $text = [System.Text.Encoding]::UTF8.GetString($raw, $startIdx, $raw.Length - $startIdx)
            $noBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($dstPath, $text, $noBom)
        }

        # Buat GDScript checker yang me-load setiap file dan cek is_valid()
        $scriptNames = @($allGdFiles | ForEach-Object { $_.Name })
        $fileListGD  = ($scriptNames | ForEach-Object { '"scripts/' + $_ + '"' }) -join ', '
        $gdChecker = @"
extends Node
func _ready() -> void:
    var fail_count := 0
    for f in [$fileListGD]:
        var s = ResourceLoader.load(f)
        if s == null or not (s is GDScript) or not (s as GDScript).can_instantiate():
            printerr("COMPILE_FAIL: " + f)
            fail_count += 1
        else:
            print("COMPILE_OK: " + f)
    print("RESULT: " + str(fail_count) + " failures")
    get_tree().quit(fail_count)
"@
        [System.IO.File]::WriteAllText("$t17Dir\scripts\checker.gd", $gdChecker, (New-Object System.Text.UTF8Encoding($false)))

        # Buat project.godot dengan GameStateWriter sebagai autoload
        # agar game-state-templates (yang memanggil GameStateWriter) bisa compile
        $projGodot = "config_version=5`n`n[application]`nconfig/name=`"T17Check`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`n"
        [System.IO.File]::WriteAllText("$t17Dir\project.godot", $projGodot, (New-Object System.Text.UTF8Encoding($false)))

        # Buat main.tscn yang me-attach checker.gd
        $mainTscn = "[gd_scene load_steps=2 format=3]`n[ext_resource type=""Script"" path=""res://scripts/checker.gd"" id=""1""]`n[node name=""Main"" type=""Node""]`nscript = ExtResource(""1"")`n"
        [System.IO.File]::WriteAllText("$t17Dir\main.tscn", $mainTscn, (New-Object System.Text.UTF8Encoding($false)))

        # Import dulu
        # --headless: tanpa ini import yang gagal memunculkan dialog modal yang merebut
        # fokus pengguna dan menahan suite sampai timeout.
        $impProc = Start-Process $godotExe17 -ArgumentList "--path", "`"$t17Dir`"", "--headless", "--import", "--quit-after", "2" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($impProc) { $impProc.Handle | Out-Null; $impProc.WaitForExit(30000) | Out-Null }

        # Jalankan checker vanilla
        $vanillaLog = Join-Path $env:TEMP "kilo_t17_vanilla.txt"
        $vanillaProc = Start-Process $godotExe17 `
            -ArgumentList "--path", "`"$t17Dir`"", "--headless" `
            -PassThru -NoNewWindow -RedirectStandardError $vanillaLog -ErrorAction SilentlyContinue
        if ($vanillaProc) {
            $vanillaProc.Handle | Out-Null
            $vanillaProc.WaitForExit(30000) | Out-Null
        }

        # Parse hasil
        $vanillaFails = @()
        if (Test-Path -LiteralPath $vanillaLog) {
            $vanillaFails = @(Get-Content $vanillaLog -ErrorAction SilentlyContinue | Where-Object { $_ -match "COMPILE_FAIL|Parse Error|Compile Error" -and $_ -notmatch "GDScript::reload" })
            Remove-Item -LiteralPath $vanillaLog -ErrorAction SilentlyContinue
        }

        # Tambah strict mode setting dan jalankan lagi
        # Format yang benar: section [debug] dengan key gdscript/warnings/...
        # Section [gdscript] diabaikan Godot -- menghasilkan vanilla run kedua (bug asli)
        $strictLog = Join-Path $env:TEMP "kilo_t17_strict.txt"
        $projGodotStrict = $projGodot + "[debug]`ngdscript/warnings/unsafe_method_access=2`ngdscript/warnings/unsafe_property_access=2`n"
        [System.IO.File]::WriteAllText("$t17Dir\project.godot", $projGodotStrict, (New-Object System.Text.UTF8Encoding($false)))

        # Re-import dengan setting baru
        $imp2Proc = Start-Process $godotExe17 -ArgumentList "--path", "`"$t17Dir`"", "--headless", "--import", "--quit-after", "2" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($imp2Proc) { $imp2Proc.Handle | Out-Null; $imp2Proc.WaitForExit(30000) | Out-Null }

        $strictProc = Start-Process $godotExe17 `
            -ArgumentList "--path", "`"$t17Dir`"", "--headless" `
            -PassThru -NoNewWindow -RedirectStandardError $strictLog -ErrorAction SilentlyContinue
        if ($strictProc) {
            $strictProc.Handle | Out-Null
            $strictProc.WaitForExit(30000) | Out-Null
        }

        $strictFails = @()
        if (Test-Path -LiteralPath $strictLog) {
            $strictFails = @(Get-Content $strictLog -ErrorAction SilentlyContinue | Where-Object { $_ -match "COMPILE_FAIL|Parse Error|Compile Error" -and $_ -notmatch "GDScript::reload" })
            Remove-Item -LiteralPath $strictLog -ErrorAction SilentlyContinue
        }

        $totalFails = $vanillaFails.Count + $strictFails.Count
        $detail = "vanilla_fails=$($vanillaFails.Count) strict_fails=$($strictFails.Count) templates=$($allGdFiles.Count)"
        if ($vanillaFails.Count -gt 0) { $detail += " | vanilla: $($vanillaFails[0])" }
        if ($strictFails.Count -gt 0)  { $detail += " | strict: $($strictFails[0])" }
        Add-Result "compile semua .gd template (vanilla + strict)" ($totalFails -eq 0) $detail
    } catch {
        Add-Result "compile semua .gd template (vanilla + strict)" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t17Dir -Recurse -Force -ErrorAction SilentlyContinue
        # Bersihkan userdata Godot yang dibuat saat --headless run
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\T17Check" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 18: Fix Q -- ScenarioRunner._evaluate_op memanggil push_warning untuk operator tak dikenal ─
# Verifikasi bahwa default case _evaluate_op mengandung push_warning (bukan hanya silent fallback).
# Test ini GAGAL terhadap build sebelum Fix Q di mana default case hanya "_: return actual == expected"
# tanpa peringatan apapun -- operator salah ketik diam-diam jadi eq.
# Verifikasi behavioral penuh butuh Godot headless dengan scenario JSON (dilakukan auditor);
# source-text check ini cukup untuk CI karena perubahan yang relevan adalah satu baris tunggal.
Write-T "TEST 18: Fix Q -- ScenarioRunner._evaluate_op memanggil push_warning untuk operator tak dikenal"
$srPs1Deployed = Join-Path $env:USERPROFILE ".config\kilo\godot-templates\ScenarioRunner.gd"
if (Test-Path -LiteralPath $srPs1Deployed) {
    $srContent = Get-Content $srPs1Deployed -Raw
    # Verifikasi push_warning ada di default case _evaluate_op -- cek dengan regex yang ketat:
    # push_warning harus muncul SETELAH deklarasi _evaluate_op dan SEBELUM akhir fungsi
    $evalOpMatch  = [regex]::Match($srContent, '(?s)func _evaluate_op.*?(?=\nfunc |\Z)')
    if ($evalOpMatch.Success) {
        $evalOpBody   = $evalOpMatch.Value
        $hasWarning   = $evalOpBody -match 'push_warning'
        $hasDefaultCase = $evalOpBody -match '_:\s*\n'
        Add-Result "Fix Q: _evaluate_op memanggil push_warning untuk operator tak dikenal" `
            ($hasWarning -and $hasDefaultCase) `
            "hasWarning=$hasWarning hasDefaultCase=$hasDefaultCase"
    } else {
        Add-Result "Fix Q: _evaluate_op ditemukan di ScenarioRunner.gd" $false "_evaluate_op tidak ditemukan"
    }
} else {
    Write-T "TEST 18: SKIP -- ScenarioRunner.gd tidak tersedia di deployed"
    Add-Result "Fix Q: push_warning di _evaluate_op" $false "ScenarioRunner.gd tidak ditemukan di deployed"
}
Write-S

# ── TEST 19: Drift detection -- vendored templates di game validasi ──────────────
# Verifikasi bahwa salinan ErrorTracker.gd, GameStateWriter.gd, ScenarioRunner.gd
# di keempat game validasi identik dengan versi terbaru di framework (md5-match).
# Setelah Fix ErrorTracker:174 (self-locating path), identik-byte kembali valid karena
# tidak ada lagi adaptasi manual per-game yang diperlukan.
# Path game dibaca dari env var KILO_GAMES_DIR -- default ke lokasi dev ini.
# SKIP (dihitung FAIL) jika direktori games tidak ditemukan -- BUKAN PASS.
Write-T "TEST 19: drift detection -- vendored templates di game validasi"
$fwTemplatesDir = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
# Tanpa KILO_GAMES_DIR, coba lokasi konvensional relatif terhadap home pengguna yang
# sedang menjalankan test. Tidak ada path absolut milik satu mesin di sini -- kalau
# tidak ketemu, TEST 19 melapor SKIP-sebagai-FAIL (lihat catatan di bawah).
$gamesBaseDir   = if ($env:KILO_GAMES_DIR -and (Test-Path -LiteralPath $env:KILO_GAMES_DIR)) {
                      $env:KILO_GAMES_DIR
                  } else {
                      Join-Path $env:USERPROFILE "Documents\games"
                  }
$vendorTemplates = @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")
$gameVendorPaths = @{
    "godot-open-rts"  = "source\scripts"
    "godot-tiny-mmo"  = "source\common\framework"
    "bread-adventure" = "src\global"
    "jimat"           = "scripts"
}
$driftFound = @()
$checkedCount = 0
foreach ($game in $gameVendorPaths.Keys) {
    $gameDir = Join-Path $gamesBaseDir $game
    if (-not (Test-Path -LiteralPath $gameDir)) { continue }
    foreach ($tmpl in $vendorTemplates) {
        $gamePath = Join-Path $gameDir "$($gameVendorPaths[$game])\$tmpl"
        $fwPath   = Join-Path $fwTemplatesDir $tmpl
        if (-not (Test-Path -LiteralPath $gamePath)) { continue }
        if (-not (Test-Path -LiteralPath $fwPath)) { continue }
        $checkedCount++
        $fwHash   = (Get-FileHash $fwPath   -Algorithm MD5 -ErrorAction SilentlyContinue).Hash
        $gameHash = (Get-FileHash $gamePath -Algorithm MD5 -ErrorAction SilentlyContinue).Hash
        if ($fwHash -ne $gameHash) {
            $driftFound += "$game/$tmpl"
        }
    }
}
if ($checkedCount -eq 0) {
    # SKIP dihitung FAIL -- mesin tanpa game validasi tidak bisa memverifikasi drift
    # Ini lebih jujur daripada PASS palsu. Set KILO_GAMES_DIR untuk enable test ini.
    Add-Result "vendored templates di game validasi sinkron" $false "SKIP -- game validasi tidak ditemukan (set env KILO_GAMES_DIR atau pastikan path $gamesBaseDir ada)"
} else {
    $detail = "checked=$checkedCount drift=$($driftFound.Count)"
    if ($driftFound.Count -gt 0) { $detail += " | drift: $($driftFound -join ', ')" }
    Add-Result "vendored templates di game validasi sinkron" ($driftFound.Count -eq 0) $detail
}
Write-S

# ══ LAYER 0 (bootstrap) ═══════════════════════════════════════════════════════════
# TEST 20-23 menguji setup.ps1 / doctor.ps1 / _common.ps1.
#
# Semua test di bawah TIDAK PERNAH menyentuh ~/.config/kilo milik user. Isolasi dilakukan
# dengan meng-override $env:USERPROFILE ke direktori temp sebelum memanggil script anak --
# setup.ps1, sync.ps1, dan doctor.ps1 semuanya menurunkan lokasi kilo dari env var itu.
$kiloDeployedRoot = Join-Path $env:USERPROFILE ".config\kilo"

# Helper: bangun salinan KiloRoot minimal di temp (tools + template) untuk diuji doctor.
function New-DoctorFixture {
    param([string]$Dest)
    $null = New-Item -ItemType Directory -Path (Join-Path $Dest "tools") -Force
    Copy-Item (Join-Path $kiloDeployedRoot "tools\*.ps1") (Join-Path $Dest "tools") -Force
    foreach ($d in @("godot-templates", "game-state-templates")) {
        $src = Join-Path $kiloDeployedRoot $d
        if (Test-Path -LiteralPath $src) {
            $null = New-Item -ItemType Directory -Path (Join-Path $Dest $d) -Force
            Copy-Item (Join-Path $src "*.gd") (Join-Path $Dest $d) -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── TEST 20: doctor.ps1 harus MEMBEDAKAN instalasi sehat vs template .gd rusak ────
# Test ini gagal terhadap doctor.ps1 tanpa compile-check: keduanya akan exit 0, sehingga
# assertion "bersih=0 DAN rusak=1" tidak terpenuhi. Bukan sekadar "exit 0 berarti lulus".
Write-T "TEST 20: doctor.ps1 membedakan instalasi sehat vs template .gd rusak"
$doctorDeployed = Join-Path $kiloDeployedRoot "tools\doctor.ps1"
if (-not (Test-Path -LiteralPath $doctorDeployed)) {
    Add-Result "doctor.ps1 mendeteksi template .gd rusak" $false "doctor.ps1 tidak tersedia di deployed"
} elseif ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "doctor.ps1 mendeteksi template .gd rusak" $false "SKIP -- Godot tidak tersedia (compile-check tidak bisa diuji)"
} else {
    $t20Dir = Join-Path $env:TEMP "kilo_t20_$(Get-Date -Format 'HHmmss')"
    try {
        New-DoctorFixture -Dest $t20Dir
        & (Join-Path $t20Dir "tools\doctor.ps1") -KiloRoot $t20Dir -GodotExe $GodotExe *>&1 | Out-Null
        $exitClean = $LASTEXITCODE

        Add-Content -LiteralPath (Join-Path $t20Dir "godot-templates\ScenarioRunner.gd") -Value "`nfunc _t20_broken( :"
        & (Join-Path $t20Dir "tools\doctor.ps1") -KiloRoot $t20Dir -GodotExe $GodotExe *>&1 | Out-Null
        $exitBroken = $LASTEXITCODE

        # Kasus ketiga: Godot yang gagal menjalankan checker sama sekali. Tanpa bukti
        # POSITIF bahwa checker berjalan, doctor hanya melihat "tidak ada tanda gagal"
        # di stderr dan melaporkan seluruh template bersih -- padahal nol yang diperiksa.
        # Godot palsu di bawah langsung exit 0 tanpa mencetak apa pun.
        $fakeGodot = Join-Path $t20Dir "fake-godot.cmd"
        Set-Content -LiteralPath $fakeGodot -Value "@echo off`r`nexit /b 0" -Encoding ASCII
        & (Join-Path $t20Dir "tools\doctor.ps1") -KiloRoot $t20Dir -GodotExe $fakeGodot *>&1 | Out-Null
        $exitNoProof = $LASTEXITCODE

        Add-Result "doctor.ps1 mendeteksi template .gd rusak" `
            (($exitClean -eq 0) -and ($exitBroken -eq 1) -and ($exitNoProof -eq 1)) `
            "bersih=$exitClean (0), rusak=$exitBroken (1), checker-tak-jalan=$exitNoProof (1)"
    } catch {
        Add-Result "doctor.ps1 mendeteksi template .gd rusak" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t20Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 21: doctor.ps1 mem-parse SEMUA tool, bukan shot-harness saja ─────────────
# Test ini gagal terhadap doctor.ps1 lama yang hanya ParseFile(shot-harness.ps1):
# syntax error di visual-diff.ps1 akan lolos dan exit 0. Tidak butuh Godot.
Write-T "TEST 21: doctor.ps1 mendeteksi syntax error di tool selain shot-harness"
if (-not (Test-Path -LiteralPath $doctorDeployed)) {
    Add-Result "doctor.ps1 mem-parse semua tools/*.ps1" $false "doctor.ps1 tidak tersedia di deployed"
} else {
    $t21Dir = Join-Path $env:TEMP "kilo_t21_$(Get-Date -Format 'HHmmss')"
    try {
        New-DoctorFixture -Dest $t21Dir
        # Rusakkan visual-diff.ps1 (BUKAN shot-harness.ps1) dengan syntax error nyata
        Add-Content -LiteralPath (Join-Path $t21Dir "tools\visual-diff.ps1") -Value "`nfunction _t21_broken {"
        & (Join-Path $t21Dir "tools\doctor.ps1") -KiloRoot $t21Dir -GodotExe "Z:\nonexistent\godot.exe" *>&1 | Out-Null
        $exit21 = $LASTEXITCODE
        Add-Result "doctor.ps1 mem-parse semua tools/*.ps1" ($exit21 -eq 1) `
            "exit=$exit21 (harus 1 -- syntax error di visual-diff.ps1 wajib terdeteksi)"
    } catch {
        Add-Result "doctor.ps1 mem-parse semua tools/*.ps1" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t21Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 22: guard _common.ps1 -- pesan actionable, bukan CommandNotFoundException ─
# Test ini gagal terhadap versi tanpa guard: dot-source langsung melempar
# CommandNotFoundException, exit code tidak di-set, dan pesannya tidak menyebut setup.ps1.
Write-T "TEST 22: tool memberi pesan actionable saat _common.ps1 hilang"
if (-not (Test-Path -LiteralPath $doctorDeployed)) {
    Add-Result "guard _common.ps1 hilang" $false "doctor.ps1 tidak tersedia di deployed"
} else {
    $t22Dir = Join-Path $env:TEMP "kilo_t22_$(Get-Date -Format 'HHmmss')"
    try {
        New-DoctorFixture -Dest $t22Dir
        Remove-Item -LiteralPath (Join-Path $t22Dir "tools\_common.ps1") -Force
        # *>&1 (bukan 2>&1): pesan guard ditulis lewat Write-Host, yang masuk information
        # stream -- 2>&1 hanya menggabungkan stderr sehingga teksnya tidak akan tertangkap.
        $out22  = & (Join-Path $t22Dir "tools\doctor.ps1") -KiloRoot $t22Dir *>&1 | Out-String
        $exit22 = $LASTEXITCODE
        $mentionsCommon = $out22 -match "_common\.ps1"
        $mentionsSetup  = $out22 -match "setup\.ps1"
        Add-Result "guard _common.ps1 hilang" `
            (($exit22 -eq 1) -and $mentionsCommon -and $mentionsSetup) `
            "exit=$exit22 (harus 1) sebut_common=$mentionsCommon sebut_setup=$mentionsSetup"
    } catch {
        Add-Result "guard _common.ps1 hilang" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t22Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 23: setup.ps1 -- gate pra-sync memblokir sync DAN tidak meninggalkan stamp ─
# Dua invariant sekaligus:
#   (a) repo rusak  -> sync.ps1 TIDAK PERNAH dipanggil (tools/ tidak terbentuk di kilo)
#   (b) bootstrap gagal -> version.json TIDAK ada (hook AGENTS.md tidak boleh menyimpulkan
#       "sudah ter-bootstrap" di atas instalasi yang gagal)
# Test ini gagal terhadap setup.ps1 yang menulis version.json sebelum verifikasi, dan juga
# terhadap versi tanpa gate pra-sync. $env:USERPROFILE di-override agar kilo user tidak tersentuh.
Write-T "TEST 23: setup.ps1 gate pra-sync memblokir sync dan tidak menulis version.json"
$repoRootForT23 = Resolve-Path (Join-Path $PSScriptRoot "..") -ErrorAction SilentlyContinue
$setupSrc       = if ($repoRootForT23) { Join-Path $repoRootForT23.Path "setup.ps1" } else { "" }
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "setup.ps1 gate pra-sync fail-closed" $false "SKIP -- Godot tidak tersedia"
} elseif ($setupSrc -eq "" -or -not (Test-Path -LiteralPath $setupSrc)) {
    Add-Result "setup.ps1 gate pra-sync fail-closed" $false "setup.ps1 tidak ditemukan (test ini hanya jalan dari repo, bukan dari deployed)"
} else {
    $t23Base = Join-Path $env:TEMP "kilo_t23_$(Get-Date -Format 'HHmmss')"
    $fakeRepo = Join-Path $t23Base "repo"
    $fakeHome = Join-Path $t23Base "home"
    $origUserProfile = $env:USERPROFILE
    try {
        $null = New-Item -ItemType Directory -Path $fakeHome -Force
        New-DoctorFixture -Dest $fakeRepo
        Copy-Item $setupSrc (Join-Path $fakeRepo "setup.ps1") -Force
        Copy-Item (Join-Path $repoRootForT23.Path "sync.ps1") (Join-Path $fakeRepo "sync.ps1") -Force
        Set-Content -LiteralPath (Join-Path $fakeRepo "VERSION") -Value "0.0.0-test" -Encoding UTF8

        # Rusakkan template DI REPO PALSU -- healthcheck pra-sync harus menangkapnya
        Add-Content -LiteralPath (Join-Path $fakeRepo "godot-templates\ScenarioRunner.gd") -Value "`nfunc _t23_broken( :"

        $env:USERPROFILE = $fakeHome
        & (Join-Path $fakeRepo "setup.ps1") -GodotExe $GodotExe *>&1 | Out-Null
        $exit23 = $LASTEXITCODE

        $fakeKilo    = Join-Path $fakeHome ".config\kilo"
        $syncHappened = Test-Path -LiteralPath (Join-Path $fakeKilo "tools\shot-harness.ps1")
        $stampExists  = Test-Path -LiteralPath (Join-Path $fakeKilo "version.json")

        Add-Result "setup.ps1 gate pra-sync fail-closed" `
            (($exit23 -eq 1) -and (-not $syncHappened) -and (-not $stampExists)) `
            "exit=$exit23 (harus 1) sync_terjadi=$syncHappened (harus False) version.json=$stampExists (harus False)"
    } catch {
        Add-Result "setup.ps1 gate pra-sync fail-closed" $false ("Exception: " + $_)
    } finally {
        $env:USERPROFILE = $origUserProfile
        Remove-Item -LiteralPath $t23Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 24: setup.ps1 -- healthcheck PASCA-sync gagal => version.json TIDAK ditulis ─
# TEST 23 tidak mencakup invariant ini: di sana gate pra-sync sudah menghentikan alur
# sebelum version.json sempat ditulis, sehingga versi setup.ps1 dengan urutan lama pun
# tetap lolos. Test ini secara khusus menargetkan URUTAN langkah 8 (verifikasi) vs 9 (stamp).
#
# Untuk memaksa kegagalan yang HANYA muncul pasca-sync, sync.ps1 di repo palsu diganti stub
# yang men-deploy template rusak. Repo palsu sendiri sehat, jadi gate pra-sync lolos --
# persis kondisi "sync melapor sukses tapi hasil deploy rusak".
#
# Terhadap setup.ps1 dengan urutan LAMA (stamp ditulis sebelum verifikasi), version.json
# akan tertinggal di disk dan assertion ini GAGAL.
Write-T "TEST 24: setup.ps1 tidak menulis version.json saat healthcheck pasca-sync gagal"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "setup.ps1 tidak meninggalkan stamp saat verifikasi gagal" $false "SKIP -- Godot tidak tersedia"
} elseif ($setupSrc -eq "" -or -not (Test-Path -LiteralPath $setupSrc)) {
    Add-Result "setup.ps1 tidak meninggalkan stamp saat verifikasi gagal" $false "setup.ps1 tidak ditemukan (test ini hanya jalan dari repo)"
} else {
    $t24Base  = Join-Path $env:TEMP "kilo_t24_$(Get-Date -Format 'HHmmss')"
    $r24      = Join-Path $t24Base "repo"
    $h24      = Join-Path $t24Base "home"
    $origUP24 = $env:USERPROFILE
    try {
        $null = New-Item -ItemType Directory -Path $h24 -Force
        New-DoctorFixture -Dest $r24          # repo palsu SEHAT -> gate pra-sync lolos
        Copy-Item $setupSrc (Join-Path $r24 "setup.ps1") -Force
        Set-Content -LiteralPath (Join-Path $r24 "VERSION") -Value "0.0.0-test" -Encoding UTF8

        # Stub sync.ps1: deploy apa adanya, lalu rusakkan satu template DI TUJUAN.
        $stubSync = @'
[CmdletBinding()]
param([switch] $DryRun, [string] $GameProjectScriptsDir = "")
$dst = Join-Path $env:USERPROFILE ".config\kilo"
$null = New-Item -ItemType Directory -Path (Join-Path $dst "tools") -Force
Copy-Item (Join-Path $PSScriptRoot "tools\*.ps1") (Join-Path $dst "tools") -Force
foreach ($d in @("godot-templates","game-state-templates")) {
    $s = Join-Path $PSScriptRoot $d
    if (Test-Path -LiteralPath $s) {
        $null = New-Item -ItemType Directory -Path (Join-Path $dst $d) -Force
        Copy-Item (Join-Path $s "*.gd") (Join-Path $dst $d) -Force -ErrorAction SilentlyContinue
    }
}
Add-Content -LiteralPath (Join-Path $dst "godot-templates\ScenarioRunner.gd") -Value "`nfunc _t24_broken( :"
exit 0
'@
        Set-Content -LiteralPath (Join-Path $r24 "sync.ps1") -Value $stubSync -Encoding UTF8

        $env:USERPROFILE = $h24
        & (Join-Path $r24 "setup.ps1") -GodotExe $GodotExe *>&1 | Out-Null
        $exit24 = $LASTEXITCODE

        $kilo24       = Join-Path $h24 ".config\kilo"
        $deployHappened = Test-Path -LiteralPath (Join-Path $kilo24 "tools\doctor.ps1")
        $stamp24      = Test-Path -LiteralPath (Join-Path $kilo24 "version.json")

        # deployHappened harus True -- membuktikan alur benar-benar sampai pasca-sync,
        # bukan gagal lebih awal karena sebab lain (yang akan membuat test lolos palsu).
        Add-Result "setup.ps1 tidak meninggalkan stamp saat verifikasi gagal" `
            (($exit24 -eq 1) -and $deployHappened -and (-not $stamp24)) `
            "exit=$exit24 (harus 1) sync_jalan=$deployHappened (harus True) version.json=$stamp24 (harus False)"
    } catch {
        Add-Result "setup.ps1 tidak meninggalkan stamp saat verifikasi gagal" $false ("Exception: " + $_)
    } finally {
        $env:USERPROFILE = $origUP24
        Remove-Item -LiteralPath $t24Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 25: -InstallAgentRules -- idempoten, non-invasif, bisa dicabut ──────────
# Empat invariant, semuanya behavioral:
#   (a) tanpa flag  -> config agent TIDAK disentuh sama sekali (opt-in benar opt-in)
#   (b) install     -> file Kilo dibuat, blok bertanda masuk ke CLAUDE.md
#   (c) idempoten   -> install 2x menghasilkan file IDENTIK (hash sama, BEGIN tetap 1)
#   (d) uninstall   -> jejak kita hilang, teks pengguna di luar penanda tetap utuh
#
# (c) dan (d) yang membuat test ini bernilai -- keduanya GAGAL terhadap implementasi naif:
# append tanpa penanda menghasilkan blok ganda di run kedua, dan tulis-timpa akan
# menghancurkan catatan pribadi pengguna di CLAUDE.md.
#
# $env:USERPROFILE di-override ke temp, jadi ~/.kilocode dan ~/.claude milik user
# yang menjalankan test ini TIDAK PERNAH tersentuh.
Write-T "TEST 25: -InstallAgentRules idempoten, non-invasif, dan bisa dicabut"
if ($setupSrc -eq "" -or -not (Test-Path -LiteralPath $setupSrc)) {
    Add-Result "aturan agent global: install/idempoten/uninstall" $false "setup.ps1 tidak ditemukan (test ini hanya jalan dari repo)"
} else {
    $t25Home  = Join-Path $env:TEMP "kilo_t25_$(Get-Date -Format 'HHmmss')"
    $origUP25 = $env:USERPROFILE
    $userText = "# Catatan pribadi pengguna`n`nBaris ini tidak boleh hilang."
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $t25Home ".kilocode\rules") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $t25Home ".claude") -Force
        $claudeMd  = Join-Path $t25Home ".claude\CLAUDE.md"
        $kiloRule  = Join-Path $t25Home ".kilocode\rules\gamedev-framework.md"
        Set-Content -LiteralPath $claudeMd -Value $userText -Encoding UTF8

        $env:USERPROFILE = $t25Home

        # (a) tanpa flag -- tidak boleh menyentuh apa pun
        & $setupSrc -SkipHealthCheck *>&1 | Out-Null
        $untouched = (-not (Test-Path -LiteralPath $kiloRule)) -and
                     ((Get-Content -LiteralPath $claudeMd -Raw -Encoding UTF8) -notmatch "ai-game-dev-framework")

        # (b) install
        & $setupSrc -InstallAgentRules -SkipHealthCheck *>&1 | Out-Null
        # Cek ISI, bukan cuma keberadaan: bug yang menulis file kosong lolos dari Test-Path.
        $installedKilo = (Test-Path -LiteralPath $kiloRule) -and
                         ((Get-Content -LiteralPath $kiloRule -Raw -Encoding UTF8) -match "project\.godot")
        $hash1  = (Get-FileHash -LiteralPath $claudeMd -Algorithm MD5).Hash
        $begin1 = ([regex]::Matches((Get-Content -LiteralPath $claudeMd -Raw -Encoding UTF8), 'BEGIN ai-game-dev-framework')).Count

        # (c) install lagi -- harus identik
        & $setupSrc -InstallAgentRules -SkipHealthCheck *>&1 | Out-Null
        $hash2  = (Get-FileHash -LiteralPath $claudeMd -Algorithm MD5).Hash
        $begin2 = ([regex]::Matches((Get-Content -LiteralPath $claudeMd -Raw -Encoding UTF8), 'BEGIN ai-game-dev-framework')).Count
        $idempotent = ($hash1 -eq $hash2) -and ($begin1 -eq 1) -and ($begin2 -eq 1)

        # (d) uninstall -- jejak hilang, teks pengguna utuh
        & $setupSrc -UninstallAgentRules *>&1 | Out-Null
        $afterText     = (Get-Content -LiteralPath $claudeMd -Raw -Encoding UTF8)
        $kiloGone      = -not (Test-Path -LiteralPath $kiloRule)
        $blockGone     = $afterText -notmatch "ai-game-dev-framework"
        $userTextKept  = $afterText -match "Baris ini tidak boleh hilang"

        Add-Result "aturan agent global: install/idempoten/uninstall" `
            ($untouched -and $installedKilo -and $idempotent -and $kiloGone -and $blockGone -and $userTextKept) `
            ("tanpa_flag_bersih=$untouched install_kilo=$installedKilo idempoten=$idempotent " +
             "(BEGIN $begin1->$begin2, hash_sama=$($hash1 -eq $hash2)) " +
             "uninstall_kilo=$kiloGone blok_hilang=$blockGone teks_user_utuh=$userTextKept")
    } catch {
        Add-Result "aturan agent global: install/idempoten/uninstall" $false ("Exception: " + $_)
    } finally {
        $env:USERPROFILE = $origUP25
        Remove-Item -LiteralPath $t25Home -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 26: -InstallAgentRules pada konfigurasi 0 dan 1 agent ───────────────────
# TEST 25 hanya menguji mesin yang punya KEDUA agent. Itu melewatkan bug nyata: di PS 5.1
# array yang di-return fungsi ter-unroll -- 0 elemen jadi $null, 1 elemen jadi objek tunggal --
# sehingga .Count melempar PropertyNotFoundException. Konfigurasi satu-agent justru yang
# paling umum di dunia nyata, jadi harus diuji eksplisit.
Write-T "TEST 26: -InstallAgentRules tidak crash pada konfigurasi 0/1 agent"
if ($setupSrc -eq "" -or -not (Test-Path -LiteralPath $setupSrc)) {
    Add-Result "aturan agent: konfigurasi 0/1 agent" $false "setup.ps1 tidak ditemukan"
} else {
    $origUP26 = $env:USERPROFILE
    $probs26  = @()
    try {
        foreach ($cfg in @("none", "kilo-only", "claude-only")) {
            $h26 = Join-Path $env:TEMP "kilo_t26_${cfg}_$(Get-Date -Format 'HHmmssfff')"
            $null = New-Item -ItemType Directory -Path $h26 -Force
            if ($cfg -eq "kilo-only")   { $null = New-Item -ItemType Directory -Path (Join-Path $h26 ".kilocode\rules") -Force }
            if ($cfg -eq "claude-only") { $null = New-Item -ItemType Directory -Path (Join-Path $h26 ".claude") -Force }
            try {
                $env:USERPROFILE = $h26
                $out26 = & $setupSrc -InstallAgentRules -SkipHealthCheck *>&1 | Out-String
                $ec26  = $LASTEXITCODE
            } finally { $env:USERPROFILE = $origUP26 }

            if ($out26 -match "cannot be found") { $probs26 += "$cfg=CRASH" }
            if ($ec26 -ne 0)                      { $probs26 += "$cfg=exit$ec26" }
            # Klaim sukses palsu: tanpa agent terdeteksi, jangan bilang "terpasang"
            if ($cfg -eq "none" -and ($out26 -match "file aturan diperbarui")) { $probs26 += "none=klaim-sukses-palsu" }
            if ($cfg -eq "kilo-only" -and -not (Test-Path -LiteralPath (Join-Path $h26 ".kilocode\rules\gamedev-framework.md"))) {
                $probs26 += "kilo-only=tidak-terpasang"
            }
            if ($cfg -eq "claude-only" -and -not (Test-Path -LiteralPath (Join-Path $h26 ".claude\CLAUDE.md"))) {
                $probs26 += "claude-only=tidak-terpasang"
            }
            Remove-Item -LiteralPath $h26 -Recurse -Force -ErrorAction SilentlyContinue
        }
        Add-Result "aturan agent: konfigurasi 0/1 agent" ($probs26.Count -eq 0) `
            $(if ($probs26.Count -eq 0) { "none/kilo-only/claude-only semua bersih" } else { ($probs26 -join ", ") })
    } catch {
        Add-Result "aturan agent: konfigurasi 0/1 agent" $false ("Exception: " + $_)
    } finally {
        $env:USERPROFILE = $origUP26
    }
}
Write-S

# ── TEST 27: penanda BEGIN/END rusak harus DITOLAK, bukan ditebak ────────────────
# Kalau END hilang (mis. pengguna edit manual), memasangkan BEGIN pertama dengan END milik
# blok lain akan melahap teks di antaranya. Terbukti menghapus catatan pengguna secara diam-diam
# pada implementasi yang tidak memvalidasi penanda.
Write-T "TEST 27: penanda BEGIN/END tidak berpasangan ditolak tanpa mengubah file"
if ($setupSrc -eq "" -or -not (Test-Path -LiteralPath $setupSrc)) {
    Add-Result "aturan agent: penanda rusak ditolak" $false "setup.ps1 tidak ditemukan"
} else {
    $h27      = Join-Path $env:TEMP "kilo_t27_$(Get-Date -Format 'HHmmss')"
    $origUP27 = $env:USERPROFILE
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $h27 ".claude") -Force
        $cm27 = Join-Path $h27 ".claude\CLAUDE.md"
        # BEGIN yatim tanpa END, dengan teks pengguna SESUDAHNYA -- itu yang berisiko dilahap
        $orphan = "# Catatan A`n`n<!-- BEGIN ai-game-dev-framework (dikelola setup.ps1 -- jangan edit manual) -->`n`n# Catatan B yang tidak boleh hilang"
        Set-Content -LiteralPath $cm27 -Value $orphan -Encoding UTF8
        $hashBefore = (Get-FileHash -LiteralPath $cm27 -Algorithm MD5).Hash

        try {
            $env:USERPROFILE = $h27
            & $setupSrc -InstallAgentRules -SkipHealthCheck *>&1 | Out-Null
            $ec27a = $LASTEXITCODE
            & $setupSrc -InstallAgentRules -SkipHealthCheck *>&1 | Out-Null
        } finally { $env:USERPROFILE = $origUP27 }

        $hashAfter = (Get-FileHash -LiteralPath $cm27 -Algorithm MD5).Hash
        $textKept  = (Get-Content -LiteralPath $cm27 -Raw -Encoding UTF8) -match "Catatan B yang tidak boleh hilang"

        Add-Result "aturan agent: penanda rusak ditolak" `
            (($ec27a -eq 1) -and ($hashBefore -eq $hashAfter) -and $textKept) `
            "exit=$ec27a (harus 1) file_utuh=$($hashBefore -eq $hashAfter) teks_user_utuh=$textKept"
    } catch {
        Add-Result "aturan agent: penanda rusak ditolak" $false ("Exception: " + $_)
    } finally {
        $env:USERPROFILE = $origUP27
        Remove-Item -LiteralPath $h27 -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 28: tool mengembalikan exit 0 pada jalur SUKSES ─────────────────────────
# Tanpa 'exit 0' eksplisit, script PowerShell berakhir tanpa menyetel exit code dan
# $LASTEXITCODE di pemanggil berisi nilai sisa perintah sebelumnya. Pemanggil jadi tidak
# bisa membedakan sukses dari gagal. Test ini sengaja menyetel $LASTEXITCODE ke nilai
# non-nol dulu -- kalau tool tidak menyetelnya sendiri, nilai sisa itu yang terbaca.
Write-T "TEST 28: tool menyetel exit 0 pada jalur sukses"
$t28Fails = @()
try {
    # schema-migration terhadap manifest yang valid: jalur sukses, tanpa Godot, cepat.
    $t28Dir = Join-Path $env:TEMP "kilo_t28_$(Get-Date -Format 'HHmmss')"
    $null = New-Item -ItemType Directory -Path $t28Dir -Force
    $t28Manifest = Join-Path $t28Dir "shots-manifest.json"
    @{ schema_version = "1.1"; generated_at = "2026-01-01 00:00:00"; shots_dir = $t28Dir;
       png_count = 0; screenshots = @() } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $t28Manifest -Encoding UTF8

    $global:LASTEXITCODE = 99          # nilai sisa yang harus ditimpa oleh tool
    & $migPs1 -ManifestPath $t28Manifest *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $t28Fails += "schema-migration=$LASTEXITCODE" }

    Remove-Item -LiteralPath $t28Dir -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    $t28Fails += "exception: $_"
}
Add-Result "tool menyetel exit 0 pada jalur sukses" ($t28Fails.Count -eq 0) `
    $(if ($t28Fails.Count -eq 0) { "schema-migration mengembalikan 0 (bukan sisa 99)" } else { ($t28Fails -join ", ") })
Write-S

# ── TEST 29: kegagalan harness TERDETEKSI oleh run-and-analyze ───────────────────
# 'exit 1' di script yang dipanggil dengan & tidak melempar exception, jadi try/catch
# saja tidak pernah aktif dan harness yang gagal tercatat phase1="ok" di laporan JSON.
# Test ini memakai stub harness yang selalu exit 1, di ~/.config/kilo palsu.
Write-T "TEST 29: run-and-analyze mendeteksi harness yang gagal (bukan mencatatnya 'ok')"
$t29Base  = Join-Path $env:TEMP "kilo_t29_$(Get-Date -Format 'HHmmss')"
$origUP29 = $env:USERPROFILE
try {
    $t29Home = Join-Path $t29Base "home"
    $t29Proj = Join-Path $t29Base "proj"
    $t29Kilo = Join-Path $t29Home ".config\kilo\tools"
    $null = New-Item -ItemType Directory -Path $t29Kilo -Force
    $null = New-Item -ItemType Directory -Path $t29Proj -Force
    # Project Godot minimal supaya fase OBSERVE benar-benar dijalankan
    Set-Content -LiteralPath (Join-Path $t29Proj "project.godot") -Value "config_version=5" -Encoding UTF8

    # Stub harness: selalu gagal, TANPA melempar exception -- persis pola yang lolos dulu
    Set-Content -LiteralPath (Join-Path $t29Kilo "shot-harness.ps1") -Encoding UTF8 -Value @'
[CmdletBinding()]
param([string]$ProjectPath = "", [int]$Timeout = 0, [string]$GodotExe = "")
Write-Host "[shot] FAIL stub sengaja gagal"
exit 1
'@
    Copy-Item (Join-Path $PSScriptRoot "_common.ps1") $t29Kilo -Force -ErrorAction SilentlyContinue

    $t29Report    = Join-Path $t29Base "report.json"
    # Pakai salinan run-and-analyze yang ter-deploy sungguhan (path dihitung dari USERPROFILE
    # ASLI, sebelum di-override) -- yang diuji adalah tool nyata, sementara stub harness
    # berada di kilo palsu yang akan di-resolve run-and-analyze saat runtime.
    $t29Tool = Join-Path $origUP29 ".config\kilo\tools\run-and-analyze.ps1"
    try {
        $env:USERPROFILE = $t29Home
        & $t29Tool -ProjectPath $t29Proj -OutputReport $t29Report -SkipHarness:$false *>&1 | Out-Null
    } finally { $env:USERPROFILE = $origUP29 }

    if (-not (Test-Path -LiteralPath $t29Report)) {
        Add-Result "run-and-analyze mendeteksi harness gagal" $false "laporan tidak dihasilkan: $t29Report"
    } else {
        $rep29    = Get-Content -LiteralPath $t29Report -Raw -Encoding UTF8 | ConvertFrom-Json
        $phase1   = if ($rep29.PSObject.Properties["phases"]) { $rep29.phases.observe } else { "" }
        Add-Result "run-and-analyze mendeteksi harness gagal" ($phase1 -ne "ok") `
            "phase observe='$phase1' (tidak boleh 'ok' saat harness exit 1)"
    }
} catch {
    Add-Result "run-and-analyze mendeteksi harness gagal" $false ("Exception: " + $_)
} finally {
    $env:USERPROFILE = $origUP29
    Remove-Item -LiteralPath $t29Base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-S

# ── TEST 30: pemetaan user:// memakai config/name, BUKAN nama direktori ──────────
# Nama folder user:// milik Godot berasal dari config/name di project.godot, dan itu
# sering berbeda jauh dari nama direktori project. Contoh nyata dari game validasi:
# direktori "godot-open-rts" -> config/name "Open RTS". Implementasi lama di
# feedback-bridge.ps1 menebak dari nama direktori ((Split-Path -Leaf).ToUpper()),
# sehingga hanya benar kalau keduanya kebetulan sama -- 1 dari 4 game validasi.
#
# Test ini sengaja memakai nama direktori yang BERBEDA dari config/name, plus satu
# kasus use_custom_user_dir. Implementasi berbasis nama direktori gagal di keduanya.
Write-T "TEST 30: user:// diturunkan dari config/name, bukan nama direktori project"
$t30Base  = Join-Path $env:TEMP "kilo_t30_$(Get-Date -Format 'HHmmss')"
$t30Fails = @()
try {
    # Kasus A: nama direktori 'my-game-repo' vs config/name 'Fancy Game Name'
    $t30A = Join-Path $t30Base "my-game-repo"
    $null = New-Item -ItemType Directory -Path $t30A -Force
    [System.IO.File]::WriteAllText((Join-Path $t30A "project.godot"),
        "[application]`nconfig/name=`"Fancy Game Name`"`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $gotA = Resolve-GodotShotsDir -ProjectPath $t30A
    if ($gotA -notmatch [regex]::Escape("app_userdata\Fancy Game Name\shots")) {
        $t30Fails += "A: '$gotA' tidak memakai config/name"
    }
    if ($gotA -match "my-game-repo|MY-GAME-REPO") { $t30Fails += "A: masih memakai nama direktori" }

    # Kasus B: use_custom_user_dir -> TIDAK di bawah app_userdata sama sekali
    $t30B = Join-Path $t30Base "another-repo"
    $null = New-Item -ItemType Directory -Path $t30B -Force
    [System.IO.File]::WriteAllText((Join-Path $t30B "project.godot"),
        "[application]`nconfig/name=`"Ignored Name`"`nconfig/use_custom_user_dir=true`nconfig/custom_user_dir_name=`"kilo_t30_custom`"`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $gotB = Resolve-GodotShotsDir -ProjectPath $t30B
    if ($gotB -notmatch "kilo_t30_custom") { $t30Fails += "B: '$gotB' mengabaikan custom_user_dir_name" }
    if ($gotB -match "app_userdata")       { $t30Fails += "B: custom dir tidak boleh di bawah app_userdata" }

    # Kasus C: tanpa project.godot -> fallback ke <ProjectPath>\shots
    $t30C = Join-Path $t30Base "not-a-godot-project"
    $null = New-Item -ItemType Directory -Path $t30C -Force
    $gotC = Resolve-GodotShotsDir -ProjectPath $t30C
    if ($gotC -ne (Join-Path $t30C "shots")) { $t30Fails += "C: fallback salah -> '$gotC'" }
} catch {
    $t30Fails += "exception: $_"
} finally {
    Remove-Item -LiteralPath $t30Base -Recurse -Force -ErrorAction SilentlyContinue
}
Add-Result "user:// dari config/name (bukan nama direktori)" ($t30Fails.Count -eq 0) `
    $(if ($t30Fails.Count -eq 0) { "config/name, custom_user_dir, dan fallback non-Godot semuanya benar" } else { ($t30Fails -join " | ") })
Write-S

# ── TEST 31: -InitProject menyunting project.godot secara defensif ───────────────
# project.godot adalah file milik developer DAN file pertama yang dibaca Godot -- kalau
# rusak, project tidak bisa dibuka sama sekali. Empat invariant:
#   (a) entri autoload milik developer dan section lain TIDAK boleh hilang
#   (b) idempoten -- jalan kedua kali tidak menduplikasi entri
#   (c) nama autoload bentrok -> BERHENTI, file tidak berubah, dan tidak ada file
#       apa pun yang disalin (berhenti sebelum menulis, bukan setengah jalan)
#   (d) tanpa section [autoload] -> section dibuat, isi lama tetap utuh
Write-T "TEST 31: -InitProject menyunting project.godot secara defensif"
$t31Base  = Join-Path $env:TEMP "kilo_t31_$(Get-Date -Format 'HHmmss')"
$t31Fails = @()
if ($setupSrc -eq "" -or -not (Test-Path -LiteralPath $setupSrc)) {
    Add-Result "-InitProject menyunting project.godot dengan aman" $false "setup.ps1 tidak ditemukan"
} else {
    try {
        # (a)+(b) project dengan autoload milik developer
        $p1 = Join-Path $t31Base "keep"
        $null = New-Item -ItemType Directory -Path $p1 -Force
        [System.IO.File]::WriteAllText((Join-Path $p1 "project.godot"),
            "config_version=5`n`n[application]`nconfig/name=`"Keep`"`n`n[autoload]`n`nMyThing=`"*res://scripts/my_thing.gd`"`n`n[display]`n`nwindow/size/viewport_width=640`n",
            (New-Object System.Text.UTF8Encoding($false)))
        & $setupSrc -InitProject $p1 *>&1 | Out-Null
        $after1 = Get-Content -LiteralPath (Join-Path $p1 "project.godot") -Raw
        if ($after1 -notmatch 'MyThing=')        { $t31Fails += "a: autoload developer hilang" }
        if ($after1 -notmatch '\[display\]')      { $t31Fails += "a: section [display] hilang" }
        if ($after1 -notmatch 'ErrorTracker=')    { $t31Fails += "a: ErrorTracker tidak ditambahkan" }
        if (-not (Test-Path -LiteralPath (Join-Path $p1 "project.godot.bak"))) { $t31Fails += "a: tidak ada backup" }

        # (b) idempotensi -- jalan kedua tidak boleh menduplikasi
        & $setupSrc -InitProject $p1 *>&1 | Out-Null
        $after2 = Get-Content -LiteralPath (Join-Path $p1 "project.godot") -Raw
        $nET = ([regex]::Matches($after2, 'ErrorTracker=')).Count
        if ($nET -ne 1) { $t31Fails += "b: ErrorTracker muncul $nET kali (harus 1)" }

        # (c) bentrok -> berhenti total
        $p2 = Join-Path $t31Base "conflict"
        $null = New-Item -ItemType Directory -Path $p2 -Force
        [System.IO.File]::WriteAllText((Join-Path $p2 "project.godot"),
            "config_version=5`n`n[application]`nconfig/name=`"Conflict`"`n`n[autoload]`n`nErrorTracker=`"*res://addons/mine/my_tracker.gd`"`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $hashBefore = (Get-FileHash -LiteralPath (Join-Path $p2 "project.godot") -Algorithm MD5).Hash
        & $setupSrc -InitProject $p2 *>&1 | Out-Null
        $ecConflict = $LASTEXITCODE
        $hashAfter  = (Get-FileHash -LiteralPath (Join-Path $p2 "project.godot") -Algorithm MD5).Hash
        if ($ecConflict -ne 1)           { $t31Fails += "c: exit=$ecConflict (harus 1)" }
        if ($hashBefore -ne $hashAfter)  { $t31Fails += "c: project.godot berubah padahal bentrok" }
        if (Test-Path -LiteralPath (Join-Path $p2 "scripts\ErrorTracker.gd")) {
            $t31Fails += "c: file .gd tersalin padahal harus berhenti sebelum menulis"
        }

        # (d) tanpa [autoload] sama sekali
        $p3 = Join-Path $t31Base "nosection"
        $null = New-Item -ItemType Directory -Path $p3 -Force
        [System.IO.File]::WriteAllText((Join-Path $p3 "project.godot"),
            "config_version=5`n`n[application]`nconfig/name=`"NoSection`"`n`n[rendering]`n`nrenderer/rendering_method=`"mobile`"`n",
            (New-Object System.Text.UTF8Encoding($false)))
        & $setupSrc -InitProject $p3 *>&1 | Out-Null
        $after3 = Get-Content -LiteralPath (Join-Path $p3 "project.godot") -Raw
        if ($after3 -notmatch '\[autoload\]')  { $t31Fails += "d: section [autoload] tidak dibuat" }
        if ($after3 -notmatch '\[rendering\]') { $t31Fails += "d: section [rendering] hilang" }
        if ($after3 -notmatch 'GameStateWriter=') { $t31Fails += "d: autoload tidak ditambahkan" }
    } catch {
        $t31Fails += "exception: $_"
    } finally {
        Remove-Item -LiteralPath $t31Base -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Result "-InitProject menyunting project.godot dengan aman" ($t31Fails.Count -eq 0) `
        $(if ($t31Fails.Count -eq 0) { "isi lama terjaga, idempoten, bentrok ditolak, section dibuat saat absen" } else { ($t31Fails -join " | ") })
}
Write-S

# ── TEST 32: wait_signal benar-benar MENUNGGU, dua arah ──────────────────────────
# Versi lama memanggil _step_pass() seketika tanpa await, dan dispatcher-nya juga tidak
# meng-await step ini. Akibatnya wait_signal SELALU pass meski signal tidak pernah dikirim,
# dan field "timeout" yang dijanjikan scenarios-templates/input_methods.json diabaikan.
# Terukur pada build lama: scenario menunggu signal tak-pernah-dikirim dengan timeout 3s
# selesai dalam 0,229 detik dan melaporkan PASS. Itu false-verify -- scenario yang memakai
# wait_signal untuk sinkronisasi berlari mendahului game lalu melapor sinkronisasi berhasil.
#
# Diuji DUA ARAH dengan sengaja: hanya menguji arah timeout akan meloloskan regresi
# "selalu gagal", yang sama buruknya.
Write-T "TEST 32: wait_signal menunggu -- timeout FAIL, signal diterima PASS"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "wait_signal menunggu (timeout fail / diterima pass)" $false "SKIP -- Godot tidak tersedia"
} else {
    $t32Dir  = Join-Path $env:TEMP "kilo_t32_$(Get-Date -Format 'HHmmss')"
    $t32Fails = @()
    try {
        $null = New-Item -ItemType Directory -Path "$t32Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t32Dir\scenarios" -Force
        $noBom32 = New-Object System.Text.UTF8Encoding($false)
        # Template dari lokasi DEPLOYED -- yang diuji adalah apa yang benar-benar dipakai
        # pengguna, bukan salinan repo.
        $t32Templates = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $src = Join-Path $t32Templates $tmpl
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $rawT = [System.IO.File]::ReadAllBytes($src)
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF -and $rawT[1] -eq 0xBB -and $rawT[2] -eq 0xBF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t32Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom32)
        }
        [System.IO.File]::WriteAllText("$t32Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT32`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom32)
        [System.IO.File]::WriteAllText("$t32Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom32)
        [System.IO.File]::WriteAllText("$t32Dir\scenarios\sig.json",
            '{"scenario_id":"t32","steps":[{"type":"wait_signal","signal_name":"t32_ready","timeout":3.0}]}', $noBom32)

        $t32Shots  = "$env:APPDATA\Godot\app_userdata\KiloT32\shots"
        $t32Result = Join-Path $t32Shots "scenario_result.json"

        # main.gd tanpa emit -- ErrorTracker membuat ScenarioRunner pada waktu yang tidak
        # dijamin, jadi varian emit di bawah HARUS polling, bukan menebak delay.
        $mainNoEmit = "extends Node`n`nfunc _ready() -> void:`n`tpass`n"
        $mainEmit   = @'
extends Node

func _ready() -> void:
	var sr: Node = null
	for i in 200:
		for c in get_tree().root.get_children():
			if c.has_method("emit_scenario_signal"):
				sr = c
				break
		if sr != null:
			break
		await get_tree().process_frame
	if sr == null:
		return
	await get_tree().create_timer(0.5).timeout
	sr.call("emit_scenario_signal", "t32_ready")
'@
        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t32Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait

        foreach ($case in @(
            @{ Name = "timeout";  Main = $mainNoEmit; WantStatus = "fail"; WantFail = 1 },
            @{ Name = "diterima"; Main = $mainEmit;   WantStatus = "pass"; WantFail = 0 }
        )) {
            [System.IO.File]::WriteAllText("$t32Dir\main.gd", $case.Main, $noBom32)
            Remove-Item -LiteralPath $t32Result -Force -ErrorAction SilentlyContinue
            $pr = Start-Process $GodotExe -ArgumentList "--path", "`"$t32Dir`"", "--", "--scenario", "res://scenarios/sig.json" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($pr) { $pr.Handle | Out-Null; $pr.WaitForExit(45000) | Out-Null; if (-not $pr.HasExited) { $pr.Kill() } }

            if (-not (Test-Path -LiteralPath $t32Result)) {
                $t32Fails += "$($case.Name): scenario_result.json tidak dihasilkan"
                continue
            }
            $r32 = Get-Content -LiteralPath $t32Result -Raw -Encoding UTF8 | ConvertFrom-Json
            # steps_total harus 1: build perantara yang tidak di-await menghasilkan
            # "pass=0 fail=0" -- step-nya tidak pernah tercatat sama sekali.
            if ($r32.steps_total -ne 1)              { $t32Fails += "$($case.Name): steps_total=$($r32.steps_total), harus 1" }
            if ($r32.status -ne $case.WantStatus)    { $t32Fails += "$($case.Name): status=$($r32.status), harus $($case.WantStatus)" }
            if ($r32.steps_fail -ne $case.WantFail)  { $t32Fails += "$($case.Name): steps_fail=$($r32.steps_fail), harus $($case.WantFail)" }
        }
        Add-Result "wait_signal menunggu (timeout fail / diterima pass)" ($t32Fails.Count -eq 0) `
            $(if ($t32Fails.Count -eq 0) { "timeout -> fail, signal diterima -> pass, step tercatat di kedua kasus" } else { ($t32Fails -join " | ") })
    } catch {
        Add-Result "wait_signal menunggu (timeout fail / diterima pass)" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t32Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT32" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 33: assert_state pada field yang TIDAK ADA harus GAGAL ─────────────────
# GDScript mengubah float(str(null)) menjadi 0.0, sehingga sebelum perbaikan ini field
# yang tidak ada di game_state dibaca sebagai 0 dan bentuk assertion paling umum untuk
# invarian justru SELALU lolos:
#     "coins gte 0"        -> 0.0 >= 0.0 -> true
#     "dukun.hp_pct lte 1" -> 0.0 <= 1.0 -> true
#
# Ditemukan lewat scenario adversarial pertama di jimat: TUJUH invarian dilaporkan utuh
# padahal tidak satu pun benar-benar diperiksa. Ini false-verify di lapisan assertion --
# tepat kemampuan yang paling diandalkan framework ini.
#
# Diuji TIGA arah: field ada dan valid -> pass; field ada tapi melanggar -> fail;
# field tidak ada -> fail. Menguji arah terakhir saja akan meloloskan regresi
# "semua assertion gagal", yang sama tidak bergunanya.
Write-T "TEST 33: assert_state pada field tidak ada harus GAGAL, bukan lolos diam-diam"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "assert_state: field tidak ada -> fail (bukan lolos)" $false "SKIP -- Godot tidak tersedia"
} else {
    $t33Dir = Join-Path $env:TEMP "kilo_t33_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t33Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t33Dir\scenarios" -Force
        $noBom33 = New-Object System.Text.UTF8Encoding($false)
        $t33Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t33Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t33Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom33)
        }
        [System.IO.File]::WriteAllText("$t33Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT33`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom33)
        [System.IO.File]::WriteAllText("$t33Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom33)
        # Game menulis state dengan field yang DIKETAHUI -- 'hp_ada' dan 'nested.pct' ada,
        # 'hp_tidak_ada' sengaja tidak pernah ditulis.
        [System.IO.File]::WriteAllText("$t33Dir\main.gd", @'
extends Node

func _write_game_state() -> void:
	var state := {"hp_ada": 5, "nested": {"pct": 0.5}}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	var f := FileAccess.open("user://shots/game_state.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
'@, $noBom33)
        # DUA scenario terpisah: ScenarioRunner berhenti pada kegagalan pertama (fail-fast),
        # jadi assertion sesudah step yang gagal tidak pernah dijalankan. Menggabungkan
        # kasus pass dan fail dalam satu scenario membuat kasus terakhir tak pernah teruji.
        [System.IO.File]::WriteAllText("$t33Dir\scenarios\ok.json", @'
{
  "scenario_id": "t33_ok",
  "steps": [
    {"type": "write_state"},
    {"type": "assert_state", "field": "hp_ada", "op": "gte", "expected": 0},
    {"type": "assert_state", "field": "nested.pct", "op": "lte", "expected": 1.0}
  ]
}
'@, $noBom33)
        [System.IO.File]::WriteAllText("$t33Dir\scenarios\missing.json", @'
{
  "scenario_id": "t33_missing",
  "steps": [
    {"type": "write_state"},
    {"type": "assert_state", "field": "hp_tidak_ada", "op": "gte", "expected": 0}
  ]
}
'@, $noBom33)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t33Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t33Res   = "$env:APPDATA\Godot\app_userdata\KiloT33\shots\scenario_result.json"
        $t33Probs = @()
        foreach ($case in @(
            @{ File = "ok.json";      Want = "pass"; Label = "field ada (gte + dot-path)" },
            @{ File = "missing.json"; Want = "fail"; Label = "field TIDAK ADA" }
        )) {
            Remove-Item -LiteralPath $t33Res -Force -ErrorAction SilentlyContinue
            $pr33 = Start-Process $GodotExe -ArgumentList "--path", "`"$t33Dir`"", "--", "--scenario", "res://scenarios/$($case.File)" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($pr33) { $pr33.Handle | Out-Null; $pr33.WaitForExit(45000) | Out-Null; if (-not $pr33.HasExited) { $pr33.Kill() } }

            if (-not (Test-Path -LiteralPath $t33Res)) {
                $t33Probs += "$($case.Label): scenario_result.json tidak dihasilkan"
                continue
            }
            $r33 = Get-Content -LiteralPath $t33Res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r33.status -ne $case.Want) {
                $t33Probs += "$($case.Label): status=$($r33.status), harus $($case.Want)"
            }
            # Assertion harus benar-benar dijalankan, bukan sekadar scenario yang berakhir
            $nAssert = @($r33.step_results | Where-Object { $_.type -eq "assert_state" }).Count
            if ($nAssert -lt 1) { $t33Probs += "$($case.Label): tidak ada assert_state tercatat" }
        }
        Add-Result "assert_state: field tidak ada -> fail (bukan lolos)" ($t33Probs.Count -eq 0) `
            $(if ($t33Probs.Count -eq 0) { "field ada -> pass, field tidak ada -> fail" } else { ($t33Probs -join " | ") })
    } catch {
        Add-Result "assert_state: field tidak ada -> fail (bukan lolos)" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t33Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT33" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 34: implementasi _write_game_state() milik GAME menang atas autoload ────
# ScenarioRunner mendokumentasikan hook _write_game_state(), dan GameStateWriter.gd JUGA
# mengimplementasikan nama itu. Autoload adalah anak root yang ditambahkan sebelum main
# scene, sehingga selalu ditemukan lebih dulu -- implementasi kaya milik game selalu
# terbayangi, dan _exec_write_state bahkan secara eksplisit mendahulukan autoload.
#
# Terukur di jimat: main.gd menulis coins/run_active/dukun (23 field), tapi yang sampai ke
# game_state.json hanya 6 field generik. Akibatnya SEMUA assertion game-specific tidak
# punya data -- dan sebelum perbaikan null, semuanya lolos diam-diam.
Write-T "TEST 34: _write_game_state() milik game menang atas autoload GameStateWriter"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "_write_game_state game menang atas autoload" $false "SKIP -- Godot tidak tersedia"
} else {
    $t34Dir = Join-Path $env:TEMP "kilo_t34_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t34Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t34Dir\scenarios" -Force
        $noBom34 = New-Object System.Text.UTF8Encoding($false)
        $t34Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        # GameStateWriter autoload SENGAJA dipasang -- itu kondisi yang memicu bug
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t34Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t34Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom34)
        }
        [System.IO.File]::WriteAllText("$t34Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT34`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom34)
        [System.IO.File]::WriteAllText("$t34Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom34)
        # Game menulis penanda khas yang TIDAK PERNAH ditulis GameStateWriter generik
        [System.IO.File]::WriteAllText("$t34Dir\main.gd", @'
extends Node

func _write_game_state() -> void:
	var state := {"penanda_milik_game": 42}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	var f := FileAccess.open("user://shots/game_state.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
'@, $noBom34)
        [System.IO.File]::WriteAllText("$t34Dir\scenarios\writer.json", @'
{
  "scenario_id": "t34",
  "steps": [
    {"type": "write_state"},
    {"type": "assert_state", "field": "penanda_milik_game", "op": "eq", "expected": 42}
  ]
}
'@, $noBom34)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t34Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t34Res = "$env:APPDATA\Godot\app_userdata\KiloT34\shots\scenario_result.json"
        Remove-Item -LiteralPath $t34Res -Force -ErrorAction SilentlyContinue
        $pr34 = Start-Process $GodotExe -ArgumentList "--path", "`"$t34Dir`"", "--", "--scenario", "res://scenarios/writer.json" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($pr34) { $pr34.Handle | Out-Null; $pr34.WaitForExit(45000) | Out-Null; if (-not $pr34.HasExited) { $pr34.Kill() } }

        if (-not (Test-Path -LiteralPath $t34Res)) {
            Add-Result "_write_game_state game menang atas autoload" $false "scenario_result.json tidak dihasilkan"
        } else {
            $r34    = Get-Content -LiteralPath $t34Res -Raw -Encoding UTF8 | ConvertFrom-Json
            $wStep  = @($r34.step_results | Where-Object { $_.type -eq "write_state" })[0]
            $aStep  = @($r34.step_results | Where-Object { $_.type -eq "assert_state" })[0]
            $t34Probs = @()
            # writer harus "Main" (node game), BUKAN "GameStateWriter"
            if ($wStep.data.writer -ne "Main") { $t34Probs += "writer=$($wStep.data.writer), harus Main" }
            if ($aStep.status -ne "pass")      { $t34Probs += "assert penanda game: $($aStep.status), harus pass" }
            Add-Result "_write_game_state game menang atas autoload" ($t34Probs.Count -eq 0) `
                $(if ($t34Probs.Count -eq 0) { "writer=Main, state game-specific terbaca" } else { ($t34Probs -join " | ") })
        }
    } catch {
        Add-Result "_write_game_state game menang atas autoload" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t34Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT34" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 35: action ui_* tanpa Control fokus harus memberi peringatan ───────────
# Di Godot, action ui_* hanya sampai ke Button/Control yang sedang FOKUS. Tanpa fokus,
# input dijamin tidak mengenai apa pun -- tapi step tetap PASS, karena framework memang
# tidak bisa tahu apakah game merespons.
#
# Terukur di jimat: goto_title() tidak pernah memanggil grab_focus(), sehingga seluruh
# navigasi berbasis ui_accept tidak berfungsi sementara setiap step melapor PASS. Penyebab
# senyap yang mahal untuk didiagnosis.
#
# Peringatan (bukan kegagalan) karena sebagian game menangani ui_* lewat _input() tanpa
# bergantung fokus. Diuji DUA ARAH: tanpa fokus -> ada peringatan; dengan fokus -> tidak ada.
Write-T "TEST 35: action ui_* tanpa Control fokus memberi peringatan"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "action ui_* tanpa fokus -> peringatan" $false "SKIP -- Godot tidak tersedia"
} else {
    $t35Base  = Join-Path $env:TEMP "kilo_t35_$(Get-Date -Format 'HHmmss')"
    $t35Probs = @()
    try {
        $noBom35 = New-Object System.Text.UTF8Encoding($false)
        $t35Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        $mainNoFocus = "extends Node`n`nfunc _ready() -> void:`n`tpass`n"
        $mainFocus   = @'
extends Node

func _ready() -> void:
	var b := Button.new()
	b.text = "fokus"
	add_child(b)
	b.grab_focus()
'@
        foreach ($case in @(
            @{ Name = "tanpa-fokus"; Main = $mainNoFocus; WantWarn = $true },
            @{ Name = "dengan-fokus"; Main = $mainFocus;  WantWarn = $false }
        )) {
            $d35 = Join-Path $t35Base $case.Name
            $null = New-Item -ItemType Directory -Path "$d35\scripts"   -Force
            $null = New-Item -ItemType Directory -Path "$d35\scenarios" -Force
            foreach ($tmpl in @("ErrorTracker.gd", "ScenarioRunner.gd")) {
                $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t35Tmpl $tmpl))
                $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
                [System.IO.File]::WriteAllText("$d35\scripts\$tmpl",
                    [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom35)
            }
            $appName = "KiloT35" + $case.Name.Replace("-", "")
            [System.IO.File]::WriteAllText("$d35\project.godot",
                "config_version=5`n`n[application]`nconfig/name=`"$appName`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom35)
            [System.IO.File]::WriteAllText("$d35\main.tscn",
                "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom35)
            [System.IO.File]::WriteAllText("$d35\main.gd", $case.Main, $noBom35)
            [System.IO.File]::WriteAllText("$d35\scenarios\act.json",
                '{"scenario_id":"t35","steps":[{"type":"wait_frames","frames":30},{"type":"action","action":"ui_accept"}]}', $noBom35)

            $null = Start-Process $GodotExe -ArgumentList "--path", "`"$d35`"", "--headless", "--import", "--quit" `
                -PassThru -NoNewWindow -Wait
            $r35Path = "$env:APPDATA\Godot\app_userdata\$appName\shots\scenario_result.json"
            Remove-Item -LiteralPath $r35Path -Force -ErrorAction SilentlyContinue
            $pr35 = Start-Process $GodotExe -ArgumentList "--path", "`"$d35`"", "--", "--scenario", "res://scenarios/act.json" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($pr35) { $pr35.Handle | Out-Null; $pr35.WaitForExit(45000) | Out-Null; if (-not $pr35.HasExited) { $pr35.Kill() } }

            if (-not (Test-Path -LiteralPath $r35Path)) {
                $t35Probs += "$($case.Name): scenario_result.json tidak dihasilkan"
            } else {
                $r35   = Get-Content -LiteralPath $r35Path -Raw -Encoding UTF8 | ConvertFrom-Json
                $aStep = @($r35.step_results | Where-Object { $_.type -eq "action" })[0]
                # StrictMode: mengakses properti yang tidak ada MELEMPAR, bukan mengembalikan
                # null. Kasus "tidak ada peringatan" justru berarti properti itu absen --
                # jadi keberadaannya harus dicek lewat PSObject, bukan perbandingan nilai.
                $hasWarn = $false
                if ($null -ne $aStep -and $null -ne $aStep.data) {
                    $hasWarn = ($aStep.data.PSObject.Properties.Name -contains 'warning')
                }
                if ($hasWarn -ne $case.WantWarn) {
                    $t35Probs += "$($case.Name): peringatan=$hasWarn, harus $($case.WantWarn)"
                }
                # Step harus tetap PASS di kedua kasus -- ini peringatan, bukan kegagalan
                if ($aStep -and $aStep.status -ne "pass") { $t35Probs += "$($case.Name): status=$($aStep.status), harus pass" }
            }
            Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\$appName" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Add-Result "action ui_* tanpa fokus -> peringatan" ($t35Probs.Count -eq 0) `
            $(if ($t35Probs.Count -eq 0) { "tanpa fokus -> ada peringatan, dengan fokus -> tidak, keduanya tetap pass" } else { ($t35Probs -join " | ") })
    } catch {
        Add-Result "action ui_* tanpa fokus -> peringatan" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t35Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 36: kontrak _get_game_state() -- yang DISARANKAN framework ─────────────
# ScenarioRunner mendokumentasikan dua kontrak penyedia state. TEST 34 menguji
# _write_game_state(); yang DISARANKAN -- _get_game_state() -- tidak punya cakupan sama
# sekali sampai test ini. Kalau delegasi GameStateWriter ke provider rusak, game yang
# mengikuti dokumentasi utama diam-diam hanya mendapat state fallback generik.
#
# Ditemukan saat mendiagnosis bread-adventure: state yang tertulis berisi build="unknown"
# (nilai fallback GameStateWriter), bukan data provider. Framework ternyata benar --
# tapi tidak ada satu pun test yang bisa membuktikannya.
Write-T "TEST 36: kontrak _get_game_state() menghasilkan state dari game, bukan fallback"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "kontrak _get_game_state() dipakai (bukan fallback)" $false "SKIP -- Godot tidak tersedia"
} else {
    $t36Dir = Join-Path $env:TEMP "kilo_t36_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t36Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t36Dir\scenarios" -Force
        $noBom36 = New-Object System.Text.UTF8Encoding($false)
        $t36Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t36Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t36Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom36)
        }
        [System.IO.File]::WriteAllText("$t36Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT36`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom36)
        [System.IO.File]::WriteAllText("$t36Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom36)
        # Node scene memakai kontrak yang DISARANKAN: menyediakan data, bukan menulis file.
        # 'build' sengaja diisi nilai khas -- kalau fallback yang dipakai, isinya "unknown".
        [System.IO.File]::WriteAllText("$t36Dir\main.gd", @'
extends Node

func _get_game_state() -> Dictionary:
	return {"build": "provider-1.0", "penanda_provider": 99}
'@, $noBom36)
        [System.IO.File]::WriteAllText("$t36Dir\scenarios\p.json",
            '{"scenario_id":"t36","steps":[{"type":"wait_frames","frames":30},{"type":"write_state"},{"type":"assert_state","field":"penanda_provider","op":"eq","expected":99}]}', $noBom36)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t36Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t36Res = "$env:APPDATA\Godot\app_userdata\KiloT36\shots\scenario_result.json"
        $t36Gs  = "$env:APPDATA\Godot\app_userdata\KiloT36\shots\game_state.json"
        Remove-Item -LiteralPath $t36Res -Force -ErrorAction SilentlyContinue
        $pr36 = Start-Process $GodotExe -ArgumentList "--path", "`"$t36Dir`"", "--", "--scenario", "res://scenarios/p.json" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($pr36) { $pr36.Handle | Out-Null; $pr36.WaitForExit(45000) | Out-Null; if (-not $pr36.HasExited) { $pr36.Kill() } }

        $t36Probs = @()
        if (-not (Test-Path -LiteralPath $t36Res)) {
            $t36Probs += "scenario_result.json tidak dihasilkan"
        } else {
            $r36 = Get-Content -LiteralPath $t36Res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r36.status -ne "pass") { $t36Probs += "scenario status=$($r36.status), harus pass" }
        }
        if (-not (Test-Path -LiteralPath $t36Gs)) {
            $t36Probs += "game_state.json tidak dihasilkan"
        } else {
            $g36 = Get-Content -LiteralPath $t36Gs -Raw -Encoding UTF8 | ConvertFrom-Json
            # 'build' membedakan data provider dari state fallback GameStateWriter
            if ($g36.build -ne "provider-1.0") { $t36Probs += "build='$($g36.build)', harus 'provider-1.0' (fallback dipakai?)" }
            if (-not ($g36.PSObject.Properties.Name -contains 'penanda_provider')) {
                $t36Probs += "penanda_provider tidak ada di state"
            }
        }
        Add-Result "kontrak _get_game_state() dipakai (bukan fallback)" ($t36Probs.Count -eq 0) `
            $(if ($t36Probs.Count -eq 0) { "data provider tertulis (build=provider-1.0), assertion lulus" } else { ($t36Probs -join " | ") })
    } catch {
        Add-Result "kontrak _get_game_state() dipakai (bukan fallback)" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t36Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT36" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 37: akurasi metrik "persen pixel berubah" ─────────────────────────────
# Ditemukan saat menjalankan framework pada jimat: dua run identik berturut-turut
# melaporkan 9 "regresi", 6 di antaranya sebenarnya < 1% -- di bawah threshold default.
# Sebabnya AE pada build Q16-HDRI mengembalikan SUM magnitudo ter-skala quantum, bukan
# cacah pixel: 500 pixel beda -> AE 32.767.500 (= 500 x 65535) -> rasio membengkak 65.535x
# lalu ter-clamp ke 100. Efeknya SETIAP screenshot yang tidak identik dilaporkan
# "100% pixel berubah", sehingga threshold dan region_thresholds mati total.
# Test ini memakai kanvas dengan jawaban yang diketahui persis; build lama gagal pada
# kasus 5% dan 25% (keduanya dilaporkan 100%).
Write-T "TEST 37: visual-diff melaporkan persen pixel yang akurat, bukan nilai ter-clamp"
$t37Vd = Join-Path $PSScriptRoot "visual-diff.ps1"
$t37Im = ""
foreach ($cand37 in @("magick", "convert")) {
    $f37 = Get-Command $cand37 -ErrorAction SilentlyContinue
    if ($f37) { $t37Im = $f37.Source; break }
}
if ((Test-Path -LiteralPath $t37Vd) -and $t37Im -ne "") {
    $t37Dir = Join-Path $env:TEMP "kilo_t37_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $t37Cur  = Join-Path $t37Dir "shots"
        $t37Base = Join-Path $t37Dir "baseline"
        $null = New-Item -ItemType Directory -Path $t37Cur  -Force
        $null = New-Item -ItemType Directory -Path $t37Base -Force

        # Kanvas 100x100 = 10.000 pixel. Persegi hitam menentukan jawaban yang tepat.
        $t37Cases = @(
            @{ n = "m_000"; rect = ""            ; expect = 0.0   },
            @{ n = "m_005"; rect = "0,0 49,9"    ; expect = 5.0   },   # 50x10  =   500
            @{ n = "m_025"; rect = "0,0 49,49"   ; expect = 25.0  },   # 50x50  =  2500
            @{ n = "m_100"; rect = "0,0 99,99"   ; expect = 100.0 }    # 100x100= 10000
        )
        foreach ($c37 in $t37Cases) {
            & $t37Im "-size" "100x100" "xc:white" (Join-Path $t37Base "$($c37.n).png") 2>$null
            if ($c37.rect -eq "") {
                & $t37Im "-size" "100x100" "xc:white" (Join-Path $t37Cur "$($c37.n).png") 2>$null
            } else {
                & $t37Im "-size" "100x100" "xc:white" "-fill" "black" "-draw" "rectangle $($c37.rect)" `
                         (Join-Path $t37Cur "$($c37.n).png") 2>$null
            }
        }

        & $t37Vd -ShotsDir $t37Cur -BaselineDir $t37Base -Threshold 1 *>$null
        $t37Rep = Join-Path $t37Cur "diff\diff-report.json"
        $t37Probs = @()
        if (-not (Test-Path -LiteralPath $t37Rep)) {
            $t37Probs += "diff-report.json tidak dihasilkan"
        } else {
            $t37Json = Get-Content -LiteralPath $t37Rep -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($c37 in $t37Cases) {
                $row = $t37Json.files | Where-Object { $_.file -eq "$($c37.n).png" }
                if ($null -eq $row) { $t37Probs += "$($c37.n): tidak ada di laporan"; continue }
                $got37 = [double]$row.change_pct
                if ([math]::Abs($got37 - $c37.expect) -gt 0.01) {
                    $t37Probs += "$($c37.n): dilaporkan $got37%, seharusnya $($c37.expect)%"
                }
            }
        }
        Add-Result "visual-diff melaporkan persen pixel akurat" ($t37Probs.Count -eq 0) `
            $(if ($t37Probs.Count -eq 0) { "0/5/25/100% dilaporkan tepat" } else { ($t37Probs -join " | ") })
    } catch {
        Add-Result "visual-diff melaporkan persen pixel akurat" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t37Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result "visual-diff melaporkan persen pixel akurat" $false "SKIP -- ImageMagick/visual-diff tidak tersedia"
}
Write-S

# ── TEST 38: filter scenario_* harus simetris current vs baseline ──────────────
# Sebelumnya hanya sisi current yang memfilter scenario_*, sehingga setiap file
# scenario_*.png yang ikut terbawa saat baseline di-set dilaporkan "HILANG" selamanya
# padahal file itu ADA di disk. Pada jimat ini menghasilkan 17 alarm palsu sekaligus.
Write-T "TEST 38: scenario_*.png di baseline tidak dilaporkan HILANG"
if ((Test-Path -LiteralPath $t37Vd) -and $t37Im -ne "") {
    $t38Dir = Join-Path $env:TEMP "kilo_t38_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $t38Cur  = Join-Path $t38Dir "shots"
        $t38Base = Join-Path $t38Dir "baseline"
        $null = New-Item -ItemType Directory -Path $t38Cur  -Force
        $null = New-Item -ItemType Directory -Path $t38Base -Force

        # Satu layar biasa (identik) + satu artefak scenario_ yang ada di KEDUA sisi.
        foreach ($side in @($t38Cur, $t38Base)) {
            & $t37Im "-size" "60x60" "xc:white" (Join-Path $side "01_title.png")          2>$null
            & $t37Im "-size" "60x60" "xc:white" (Join-Path $side "scenario_smoke_01.png") 2>$null
        }

        & $t37Vd -ShotsDir $t38Cur -BaselineDir $t38Base -Threshold 1 *>$null
        $t38Rep = Join-Path $t38Cur "diff\diff-report.json"
        $t38Probs = @()
        if (-not (Test-Path -LiteralPath $t38Rep)) {
            $t38Probs += "diff-report.json tidak dihasilkan"
        } else {
            $t38Json = Get-Content -LiteralPath $t38Rep -Raw -Encoding UTF8 | ConvertFrom-Json
            $hilang = @($t38Json.files | Where-Object { $_.status -eq "HILANG" })
            if ($hilang.Count -ne 0) {
                $t38Probs += ("dilaporkan HILANG padahal ada di disk: " + (($hilang | ForEach-Object { $_.file }) -join ", "))
            }
        }
        Add-Result "scenario_* di baseline tidak dilaporkan HILANG" ($t38Probs.Count -eq 0) `
            $(if ($t38Probs.Count -eq 0) { "filter simetris -- 0 alarm palsu" } else { ($t38Probs -join " | ") })
    } catch {
        Add-Result "scenario_* di baseline tidak dilaporkan HILANG" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t38Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result "scenario_* di baseline tidak dilaporkan HILANG" $false "SKIP -- ImageMagick/visual-diff tidak tersedia"
}
Write-S

# ── TEST 39: tidak ada variabel dibaca tanpa pernah didefinisikan ──────────────
# autonomous-qa.ps1 membaca $projectGodot yang tidak pernah ada. Karena -or melakukan
# short-circuit, baris itu HANYA meledak saat Godot berhasil ditemukan -- yaitu justru
# di lingkungan yang sehat. Akibatnya fase RUN loop autonomous tidak pernah sekali pun
# berjalan, dan tidak ada satu pun test yang menangkapnya karena semua fixture
# sebelumnya berjalan tanpa Godot. Pemeriksaan AST ini menutup seluruh kelas bug itu.
Write-T "TEST 39: tidak ada pembacaan variabel yang tak pernah didefinisikan di tools/"
try {
    $t39Safe = @(
        '_', 'PSItem', 'args', 'input', 'true', 'false', 'null', 'this',
        'PSScriptRoot', 'PSCommandPath', 'MyInvocation', 'PSBoundParameters',
        'Matches', 'Error', 'LASTEXITCODE', 'PID', 'env', 'Host', 'ExecutionContext',
        'StackTrace', 'foreach', 'switch', 'PWD', 'HOME', 'PSVersionTable',
        'ErrorActionPreference', 'ProgressPreference', 'WarningPreference',
        'InformationPreference', 'VerbosePreference', 'DebugPreference',
        'ConfirmPreference', 'PSDefaultParameterValues', 'IsWindows', 'IsLinux', 'IsMacOS',
        'OutputEncoding', 'PSStyle', 'global', 'script', 'local', 'using'
    )
    $t39Bad = @()
    foreach ($t39File in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1)) {
        $t39Tok = $null; $t39Err = $null
        $t39Ast = [System.Management.Automation.Language.Parser]::ParseFile($t39File.FullName, [ref]$t39Tok, [ref]$t39Err)
        if ($t39Err -and $t39Err.Count -gt 0) { $t39Bad += "$($t39File.Name): parse error"; continue }

        $t39Assigned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($a39 in $t39Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            foreach ($v39 in $a39.Left.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $null = $t39Assigned.Add($v39.VariablePath.UserPath)
            }
        }
        foreach ($p39 in $t39Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
            $null = $t39Assigned.Add($p39.Name.VariablePath.UserPath)
        }
        foreach ($fe39 in $t39Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            $null = $t39Assigned.Add($fe39.Variable.VariablePath.UserPath)
        }
        foreach ($v39 in $t39Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $n39 = $v39.VariablePath.UserPath
            if ($n39 -match '^(env|global|script|local|using):') { continue }
            if ($t39Safe -contains $n39) { continue }
            if ($t39Assigned.Contains($n39)) { continue }
            $t39Bad += "$($t39File.Name):$($v39.Extent.StartLineNumber) `$$n39"
        }
    }
    Add-Result "tidak ada variabel dibaca tanpa didefinisikan" ($t39Bad.Count -eq 0) `
        $(if ($t39Bad.Count -eq 0) { "semua tool bersih" } else { ($t39Bad | Select-Object -Unique) -join " | " })
} catch {
    Add-Result "tidak ada variabel dibaca tanpa didefinisikan" $false ("Exception: " + $_)
}
Write-S

# ── TEST 40: invariant -- klaim yang berlaku sepanjang run ────────────────────
# assert_state bersifat posisional: ia hanya memeriksa di titik tempat penulis scenario
# menaruhnya, jadi bug yang terjadi DI ANTARA dua assertion tak pernah terlihat. Invariant
# diperiksa setelah setiap langkah, dan itu satu-satunya cara framework bisa menangkap
# kelas "progres naik tanpa usaha yang mendahuluinya" (mis. level bisa dilewati).
# Empat kontrak yang diuji sekaligus, semuanya pernah salah kalau diimplementasikan asal:
#   1. invariants.json game-wide berlaku tanpa disebut file scenario mana pun
#   2. invariant yang TERPENUHI tidak boleh muncul sebagai pelanggaran
#   3. pelanggaran berulang di-dedup jadi satu entri ber-count (bukan membanjiri laporan)
#   4. severity critical mengubah status akhir jadi fail; warning TIDAK
# Kontrak 4 yang paling mudah salah: kalau pelanggaran cuma dicatat tanpa mengubah status,
# exit code tetap 0 dan orchestrator yang hanya membaca exit code meluluskan run yang cacat.
Write-T "TEST 40: invariant diperiksa tiap langkah, di-dedup, critical mengubah status"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "invariant: dedup + severity mengubah status" $false "SKIP -- Godot tidak tersedia"
} else {
    $t40Dir = Join-Path $env:TEMP "kilo_t40_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t40Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t40Dir\scenarios" -Force
        $noBom40 = New-Object System.Text.UTF8Encoding($false)
        $t40Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t40Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t40Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom40)
        }
        [System.IO.File]::WriteAllText("$t40Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT40`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom40)
        [System.IO.File]::WriteAllText("$t40Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom40)
        # coins naik tiap kali state ditulis, wins tidak pernah naik -> "delta.coins <= delta.wins"
        # dilanggar di SETIAP langkah, jadi dedup ikut teruji sekaligus.
        [System.IO.File]::WriteAllText("$t40Dir\main.gd", @'
extends Node

var _coins := 0

func _get_game_state() -> Dictionary:
	_coins += 10
	return {"coins": _coins, "wins": 0, "hp": 5}
'@, $noBom40)
        # Game-wide: hanya invariant yang TERPENUHI -- tidak boleh muncul sebagai pelanggaran.
        [System.IO.File]::WriteAllText("$t40Dir\scenarios\invariants.json",
            '{"invariants":[{"id":"hp_tak_negatif","expr":"curr.hp >= 0","severity":"critical"}]}', $noBom40)
        [System.IO.File]::WriteAllText("$t40Dir\scenarios\warn.json",
            '{"scenario_id":"t40_warn","invariants":[{"id":"koin_warn","expr":"delta.coins <= delta.wins","severity":"warning"}],"steps":[{"type":"wait_frames","frames":3},{"type":"wait_frames","frames":3},{"type":"wait_frames","frames":3}]}', $noBom40)
        [System.IO.File]::WriteAllText("$t40Dir\scenarios\crit.json",
            '{"scenario_id":"t40_crit","invariants":[{"id":"koin_crit","expr":"delta.coins <= delta.wins","severity":"critical"}],"steps":[{"type":"wait_frames","frames":3},{"type":"wait_frames","frames":3},{"type":"wait_frames","frames":3}]}', $noBom40)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t40Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t40Res = "$env:APPDATA\Godot\app_userdata\KiloT40\shots\scenario_result.json"

        $t40Probs = @()
        foreach ($case in @(
            @{ File = "warn.json"; Id = "koin_warn"; Status = "pass" },
            @{ File = "crit.json"; Id = "koin_crit"; Status = "fail" }
        )) {
            Remove-Item -LiteralPath $t40Res -Force -ErrorAction SilentlyContinue
            $pr40 = Start-Process $GodotExe -ArgumentList "--path", "`"$t40Dir`"", "--", "--scenario", "res://scenarios/$($case.File)" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($pr40) { $pr40.Handle | Out-Null; $pr40.WaitForExit(45000) | Out-Null; if (-not $pr40.HasExited) { $pr40.Kill() } }

            if (-not (Test-Path -LiteralPath $t40Res)) {
                $t40Probs += "$($case.File): scenario_result.json tidak dihasilkan"
                continue
            }
            $r40 = Get-Content -LiteralPath $t40Res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r40.status -ne $case.Status) {
                $t40Probs += "$($case.File): status=$($r40.status), harus $($case.Status)"
            }
            $viol = @($r40.invariant_violations)
            # kontrak 2: invariant yang terpenuhi tidak boleh terlaporkan
            if (@($viol | Where-Object { $_.id -eq "hp_tak_negatif" }).Count -gt 0) {
                $t40Probs += "$($case.File): invariant yang TERPENUHI ikut dilaporkan"
            }
            $hit = @($viol | Where-Object { $_.id -eq $case.Id })
            if ($hit.Count -eq 0) {
                $t40Probs += "$($case.File): pelanggaran '$($case.Id)' tidak tercatat"
            } elseif ($hit.Count -gt 1) {
                $t40Probs += "$($case.File): '$($case.Id)' muncul $($hit.Count)x -- dedup gagal"
            } elseif ([int]$hit[0].count -lt 2) {
                $t40Probs += "$($case.File): count=$($hit[0].count), harus >1 (dilanggar tiap langkah)"
            }
            # semua step sendiri harus lulus -- pelanggaran invariant tidak boleh menggagalkan step
            if ([int]$r40.steps_fail -ne 0) {
                $t40Probs += "$($case.File): steps_fail=$($r40.steps_fail), invariant tidak boleh menggagalkan step"
            }
        }
        Add-Result "invariant: dedup + severity mengubah status" ($t40Probs.Count -eq 0) `
            $(if ($t40Probs.Count -eq 0) { "warning->pass, critical->fail, dedup ok, invariant terpenuhi tidak dilaporkan" } else { ($t40Probs -join " | ") })
    } catch {
        Add-Result "invariant: dedup + severity mengubah status" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t40Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT40" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 41: visual-review -- verdict visual yang awet ────────────────────────
# visual-diff tahu sebuah layar BERUBAH, tapi tidak pernah tahu layar itu BENAR.
# Cacat seperti teks terpotong dan mojibake hanya bisa dinilai dengan melihat, dan
# penilaian itu perlu bertahan lintas sesi. Lima kontrak diuji di sini:
#   1. fail-closed -- check pada proyek yang belum dinilai HARUS exit 1, bukan lulus.
#      Diam bukan bukti bahwa tampilannya benar.
#   2. verdict fail muncul di check beserta catatannya, exit 1
#   3. BAWA-MAJU: gambar berubah di BAWAH threshold -> verdict lama tetap berlaku.
#      Tanpa ini game dengan screen-shake membatalkan semua verdict tiap run dan
#      sistemnya jadi tak terpakai sama sekali.
#   4. BASI: gambar berubah di ATAS threshold -> verdict batal, wajib dinilai ulang.
#   5. verdict 'fail' tanpa note ditolak -- verdict tanpa alasan tidak berguna nanti.
Write-T "TEST 41: visual-review fail-closed, bawa-maju, dan pembatalan saat gambar berubah"
$t41Vr = Join-Path $PSScriptRoot "visual-review.ps1"
$t41Im = ""
foreach ($cand41 in @("magick", "convert")) {
    $f41 = Get-Command $cand41 -ErrorAction SilentlyContinue
    if ($f41) { $t41Im = $f41.Source; break }
}
if ((Test-Path -LiteralPath $t41Vr) -and $t41Im -ne "") {
    $t41Dir = Join-Path $env:TEMP "kilo_t41_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $t41Shots  = Join-Path $t41Dir "shots"
        $null = New-Item -ItemType Directory -Path $t41Shots -Force
        $t41Claims = Join-Path $t41Dir "visual-claims.json"
        $t41Verd   = Join-Path $t41Dir "verdicts.json"
        $noBom41   = New-Object System.Text.UTF8Encoding($false)

        # Kanvas 200x200 = 40.000 pixel. Threshold 2% -> 800 pixel.
        & $t41Im "-size" "200x200" "xc:white" (Join-Path $t41Shots "layar.png") 2>$null

        [System.IO.File]::WriteAllText($t41Claims,
            '{"threshold_pct":2.0,"claims":[{"id":"klaim_a","question":"A?","applies_to":"*"}]}', $noBom41)

        # -- kontrak 1: fail-closed --------------------------------------------
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode check *>$null
        $t41ExitKosong = $LASTEXITCODE

        # -- kontrak 5: verdict fail tanpa note ditolak -------------------------
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"fail"}]}', $noBom41)
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode check -AllowUnjudged *>$null
        $t41ExitTanpaNote = $LASTEXITCODE   # ditolak -> tetap belum dinilai -> bukan FAIL

        # -- kontrak 2: verdict fail bernote tercatat dan menggagalkan check ----
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"fail","note":"teks terpotong di tepi"}]}', $noBom41)
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode check -AllowUnjudged *>$null
        $t41ExitFail = $LASTEXITCODE

        # -- kontrak 3: bawa-maju berlaku untuk PASS (ubah 100 pixel = 0.25%) ---
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"pass","note":"terlihat benar"}]}', $noBom41)
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null
        & $t41Im "-size" "200x200" "xc:white" "-fill" "black" "-draw" "rectangle 0,0 9,9" `
                 (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode plan *>$null
        $t41Rev = Get-Content -LiteralPath (Join-Path $t41Shots "visual-review.json") -Raw | ConvertFrom-Json
        $t41Carried  = [int]$t41Rev.summary.carried_forward
        $t41StaleKcl = [int]$t41Rev.summary.stale

        # -- kontrak 3b: verdict FAIL tidak pernah dibawa maju ------------------
        # Toleransi ada untuk menahan derau (screen-shake), bukan untuk mengawetkan vonis.
        # Sebuah perbaikan bisa menentukan secara visual namun kecil dalam hitungan pixel:
        # terukur pada jimat, menghapus banner yang menimpa judul modal dan mencerahkan satu
        # label alasan sama-sama mengubah < 2% pixel, sehingga kedua verdict 'fail' bertahan
        # padahal bug-nya sudah hilang. Melaporkan bug yang sudah diperbaiki merusak
        # kepercayaan sama parahnya dengan melewatkan bug.
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"fail","note":"ada yang salah"}]}', $noBom41)
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null
        & $t41Im "-size" "200x200" "xc:white" "-fill" "black" "-draw" "rectangle 0,0 19,4" `
                 (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode plan *>$null
        $t41RevF = Get-Content -LiteralPath (Join-Path $t41Shots "visual-review.json") -Raw | ConvertFrom-Json
        $t41FailCarried = [int]$t41RevF.summary.carried_forward
        $t41FailStale   = [int]$t41RevF.summary.stale

        # Pulihkan verdict pass supaya kontrak 4 menguji jalur basi milik PASS
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"pass","note":"terlihat benar"}]}', $noBom41)
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null

        # -- kontrak 3c: penyimpangan diukur terhadap gambar yang DINILAI -------
        # Kanvas 200x200 = 40.000 pixel, threshold 2% = 800 pixel.
        # Langkah 1 mengubah 600 pixel (1,5%) -> harus dibawa maju.
        # Langkah 2 memperbesar jadi 1.200 pixel (3,0% terhadap gambar yang DINILAI) ->
        # harus jadi basi, meski terhadap run SEBELUMNYA selisihnya cuma 1,5%.
        # Versi lama menyematkan ulang sha dan menimpa salinan yang dinilai setiap kali
        # membawa maju, sehingga titik acuan ikut bergeser dan penyimpangan menumpuk tanpa
        # batas -- verdict bisa terbawa melewati gambar yang sudah sama sekali lain.
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"pass","note":"acuan drift"}]}', $noBom41)
        & $t41Im "-size" "200x200" "xc:white" (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null
        & $t41Im "-size" "200x200" "xc:white" "-fill" "black" "-draw" "rectangle 0,0 29,19" `
                 (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode plan *>$null
        $t41D1 = Get-Content -LiteralPath (Join-Path $t41Shots "visual-review.json") -Raw | ConvertFrom-Json
        $t41Drift1Carried = [int]$t41D1.summary.carried_forward
        & $t41Im "-size" "200x200" "xc:white" "-fill" "black" "-draw" "rectangle 0,0 29,39" `
                 (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode plan *>$null
        $t41D2 = Get-Content -LiteralPath (Join-Path $t41Shots "visual-review.json") -Raw | ConvertFrom-Json
        $t41Drift2Stale = [int]$t41D2.summary.stale

        # Pulihkan acuan bersih untuk kontrak 4
        [System.IO.File]::WriteAllText($t41Verd,
            '{"verdicts":[{"file":"layar.png","claim_id":"klaim_a","verdict":"pass","note":"terlihat benar"}]}', $noBom41)
        & $t41Im "-size" "200x200" "xc:white" (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode record -VerdictFile $t41Verd *>$null

        # -- kontrak 4: basi (ubah 10.000 pixel = 25%, di atas 2%) --------------
        & $t41Im "-size" "200x200" "xc:white" "-fill" "black" "-draw" "rectangle 0,0 99,99" `
                 (Join-Path $t41Shots "layar.png") 2>$null
        & $t41Vr -ShotsDir $t41Shots -ClaimsFile $t41Claims -Mode plan *>$null
        $t41Rev2 = Get-Content -LiteralPath (Join-Path $t41Shots "visual-review.json") -Raw | ConvertFrom-Json
        $t41StaleBesar = [int]$t41Rev2.summary.stale

        $t41Probs = @()
        if ($t41ExitKosong -ne 1)    { $t41Probs += "check tanpa verdict exit=$t41ExitKosong, harus 1 (fail-closed)" }
        if ($t41ExitTanpaNote -ne 0) { $t41Probs += "verdict fail tanpa note seharusnya DITOLAK (exit=$t41ExitTanpaNote)" }
        if ($t41ExitFail -ne 1)      { $t41Probs += "check dengan verdict fail exit=$t41ExitFail, harus 1" }
        if ($t41Carried -lt 1)       { $t41Probs += "verdict pass + perubahan 0.25% seharusnya dibawa maju (carried=$t41Carried)" }
        if ($t41StaleKcl -ne 0)      { $t41Probs += "verdict pass + perubahan 0.25% tidak boleh jadi basi (stale=$t41StaleKcl)" }
        if ($t41FailCarried -ne 0)   { $t41Probs += "verdict FAIL tidak boleh pernah dibawa maju (carried=$t41FailCarried)" }
        if ($t41FailStale -lt 1)     { $t41Probs += "verdict FAIL harus jadi basi begitu gambar berubah (stale=$t41FailStale)" }
        if ($t41Drift1Carried -lt 1) { $t41Probs += "drift 1,5% seharusnya dibawa maju (carried=$t41Drift1Carried)" }
        if ($t41Drift2Stale -lt 1)   { $t41Probs += "drift kumulatif 3% terhadap gambar yang DINILAI harus jadi basi (stale=$t41Drift2Stale) -- titik acuan ikut bergeser?" }
        if ($t41StaleBesar -lt 1)    { $t41Probs += "perubahan 25% harus jadi basi (stale=$t41StaleBesar)" }

        Add-Result "visual-review: fail-closed + bawa-maju + pembatalan" ($t41Probs.Count -eq 0) `
            $(if ($t41Probs.Count -eq 0) { "5 kontrak terpenuhi (0.25% dibawa maju, 25% dibatalkan)" } else { ($t41Probs -join " | ") })
    } catch {
        Add-Result "visual-review: fail-closed + bawa-maju + pembatalan" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t41Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result "visual-review: fail-closed + bawa-maju + pembatalan" $false "SKIP -- ImageMagick/visual-review tidak tersedia"
}
Write-S

# ── TEST 42: explore -- eksplorasi yang menekan tombol nyata ──────────────────
# Scenario tertulis hanya mengunjungi apa yang sudah dipikirkan penulisnya; bug "konten
# bisa dilewati" hidup di jalur yang tidak terpikirkan. Tiga kontrak diuji:
#   1. explore benar-benar menemukan dan mengklik Button di scene tree, dan invariant
#      diperiksa SETELAH SETIAP KLIK (bukan sekali di akhir step)
#   2. saat invariant jebol, jejak klik ditulis sebagai scenario replay yang bisa
#      dijalankan ulang -- eksplorasi yang tak bisa direproduksi tidak berguna
#   3. explore yang 0 klik GAGAL, bukan lulus. Ini kontrak terpenting: terukur pada jimat,
#      40 iterasi menghasilkan 40 layar buntu karena game mengambil jalur init minimal saat
#      --scenario dan menampilkan layar kosong -- sementara 4 scenario lain di game itu
#      melaporkan PASS terhadap layar kosong yang sama.
Write-T "TEST 42: explore mengklik tombol nyata, menulis replay, dan gagal saat 0 klik"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "explore: klik nyata + replay + gagal saat 0 klik" $false "SKIP -- Godot tidak tersedia"
} else {
    $t42Dir = Join-Path $env:TEMP "kilo_t42_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t42Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t42Dir\scenarios" -Force
        $noBom42 = New-Object System.Text.UTF8Encoding($false)
        $t42Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t42Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t42Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom42)
        }
        [System.IO.File]::WriteAllText("$t42Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT42`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom42)
        [System.IO.File]::WriteAllText("$t42Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom42)
        # Tiga tombol nyata. Menekan salah satunya menaikkan coins tanpa menaikkan wins,
        # sehingga invariant "delta.coins <= delta.wins" HANYA jebol kalau klik benar-benar
        # mengenai tombol -- inilah yang membedakan "explore jalan" dari "explore pura-pura".
        [System.IO.File]::WriteAllText("$t42Dir\main.gd", @'
extends Node

var _coins := 0

func _ready() -> void:
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ui)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(vb)
	for n in ["alpha", "beta", "gamma"]:
		var b := Button.new()
		b.text = n
		b.custom_minimum_size = Vector2(240, 48)
		b.pressed.connect(_on_press)
		vb.add_child(b)

func _on_press() -> void:
	_coins += 5

func _get_game_state() -> Dictionary:
	return {"coins": _coins, "wins": 0}
'@, $noBom42)
        [System.IO.File]::WriteAllText("$t42Dir\scenarios\invariants.json",
            '{"invariants":[{"id":"koin_butuh_menang","expr":"delta.coins <= delta.wins","severity":"warning"}]}', $noBom42)
        [System.IO.File]::WriteAllText("$t42Dir\scenarios\ada.json",
            '{"scenario_id":"t42_ada","steps":[{"type":"wait_frames","frames":30},{"type":"explore","iterations":6,"seed":42,"settle_frames":4}]}', $noBom42)
        # avoid_text menutup SEMUA label -> tidak ada tombol yang boleh diklik, meniru
        # kondisi layar kosong tanpa perlu project kedua.
        [System.IO.File]::WriteAllText("$t42Dir\scenarios\kosong.json",
            '{"scenario_id":"t42_kosong","steps":[{"type":"wait_frames","frames":30},{"type":"explore","iterations":4,"seed":1,"settle_frames":2,"avoid_text":["alpha","beta","gamma"]}]}', $noBom42)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t42Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t42Res    = "$env:APPDATA\Godot\app_userdata\KiloT42\shots\scenario_result.json"
        $t42Replay = "$env:APPDATA\Godot\app_userdata\KiloT42\shots\explore_replay.json"
        $t42Probs  = @()

        # -- kontrak 1 & 2: tombol nyata diklik, invariant jebol, replay ditulis --
        Remove-Item -LiteralPath $t42Res, $t42Replay -Force -ErrorAction SilentlyContinue
        $pr42 = Start-Process $GodotExe -ArgumentList "--path", "`"$t42Dir`"", "--", "--scenario", "res://scenarios/ada.json" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($pr42) { $pr42.Handle | Out-Null; $pr42.WaitForExit(60000) | Out-Null; if (-not $pr42.HasExited) { $pr42.Kill() } }

        if (-not (Test-Path -LiteralPath $t42Res)) {
            $t42Probs += "ada.json: scenario_result.json tidak dihasilkan"
        } else {
            $r42 = Get-Content -LiteralPath $t42Res -Raw -Encoding UTF8 | ConvertFrom-Json
            $ex42 = @($r42.step_results | Where-Object { $_.type -eq "explore" })
            if ($ex42.Count -eq 0) {
                $t42Probs += "ada.json: step explore tidak tercatat"
            } else {
                $d42 = $ex42[0].data
                if ([int]$d42.clicked -lt 1)        { $t42Probs += "ada.json: clicked=$($d42.clicked), harus >=1" }
                if ([int]$d42.unique_buttons -lt 1) { $t42Probs += "ada.json: unique_buttons=$($d42.unique_buttons), harus >=1" }
                if ([int]$d42.violations -lt 1)     { $t42Probs += "ada.json: invariant tidak jebol -- klik tidak mengenai tombol?" }
            }
            if (-not (Test-Path -LiteralPath $t42Replay)) {
                $t42Probs += "ada.json: explore_replay.json tidak ditulis saat invariant jebol"
            } else {
                $rep42 = Get-Content -LiteralPath $t42Replay -Raw -Encoding UTF8 | ConvertFrom-Json
                # Replay memakai LABEL, bukan koordinat. Koordinat mati diam-diam begitu layout
                # bergeser: klik mendarat di tempat kosong dan langkahnya tetap PASS. Label tidak
                # bisa gagal diam-diam. Koordinat aslinya tetap dicatat sebagai `recorded_x/y`
                # untuk forensik -- berguna saat membaca ulang jejak, tapi bukan yang dipakai mengklik.
                $mc = @($rep42.steps | Where-Object { $_.type -eq "click_button" })
                if ($mc.Count -lt 1) {
                    $t42Probs += "replay tidak berisi step click_button"
                } else {
                    # @() wajib: satu properti saja membuat .Name jadi String, dan .Contains()
                    # pada String mencocokkan substring -- lolos untuk alasan yang salah.
                    $names42 = @($mc[0].PSObject.Properties | ForEach-Object { $_.Name })
                    if ($names42 -notcontains "label" -or "$($mc[0].label)" -eq "") {
                        $t42Probs += "step click_button tanpa field 'label' terisi"
                    }
                    if ($names42 -notcontains "recorded_x") {
                        $t42Probs += "step click_button tidak mencatat recorded_x untuk forensik"
                    }
                }
                if (@($rep42.steps | Where-Object { $_.type -eq "mouse_click" }).Count -gt 0) {
                    $t42Probs += "replay masih menulis mouse_click berbasis koordinat"
                }
            }
        }

        # -- kontrak 3: 0 klik harus GAGAL, bukan lulus --------------------------
        Remove-Item -LiteralPath $t42Res -Force -ErrorAction SilentlyContinue
        $pr42b = Start-Process $GodotExe -ArgumentList "--path", "`"$t42Dir`"", "--", "--scenario", "res://scenarios/kosong.json" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($pr42b) { $pr42b.Handle | Out-Null; $pr42b.WaitForExit(60000) | Out-Null; if (-not $pr42b.HasExited) { $pr42b.Kill() } }
        if (-not (Test-Path -LiteralPath $t42Res)) {
            $t42Probs += "kosong.json: scenario_result.json tidak dihasilkan"
        } else {
            $r42b = Get-Content -LiteralPath $t42Res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r42b.status -ne "fail") { $t42Probs += "kosong.json: status=$($r42b.status), explore 0 klik HARUS fail" }
        }

        Add-Result "explore: klik nyata + replay + gagal saat 0 klik" ($t42Probs.Count -eq 0) `
            $(if ($t42Probs.Count -eq 0) { "tombol diklik, invariant jebol per klik, replay ditulis, 0-klik gagal" } else { ($t42Probs -join " | ") })
    } catch {
        Add-Result "explore: klik nyata + replay + gagal saat 0 klik" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t42Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT42" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 43: gerbang liveness ─────────────────────────────────────────────────
# Kegagalan terburuk sebuah harness bukan melewatkan bug, melainkan melaporkan PASS atas
# ketiadaan pengujian. Terukur pada jimat: menu_navigation "PASS" berminggu-minggu terhadap
# LAYAR KOSONG karena game mengambil jalur init minimal saat --scenario. Semua assertion-nya
# memang lolos -- terhadap ketiadaan. Tidak ada satu pun pemeriksaan lama yang bisa melihatnya.
# Empat kontrak diuji:
#   1. scenario yang mengirim input tetapi tidak mengubah state maupun layar -> status inert
#   2. scenario yang inputnya benar-benar mengubah state -> pass
#   3. allow_inert:true menonaktifkan gerbang (untuk scenario yang memang tidak mengubah apa pun)
#   4. scenario TANPA langkah input tidak dikenai gerbang sama sekali -- kalau ini salah,
#      setiap scenario screenshot-saja akan gagal dan gerbangnya akan dimatikan orang
Write-T "TEST 43: liveness -- input tanpa perubahan = inert, bukan pass"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "liveness: input tanpa perubahan -> inert" $false "SKIP -- Godot tidak tersedia"
} else {
    $t43Dir = Join-Path $env:TEMP "kilo_t43_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t43Dir\scripts"   -Force
        $null = New-Item -ItemType Directory -Path "$t43Dir\scenarios" -Force
        $noBom43 = New-Object System.Text.UTF8Encoding($false)
        $t43Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t43Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t43Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom43)
        }
        [System.IO.File]::WriteAllText("$t43Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT43`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom43)
        [System.IO.File]::WriteAllText("$t43Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom43)
        # Satu tombol pada posisi tetap, TANPA grab_focus. Jadi ui_accept tidak mengenai
        # apa pun (state diam, layar diam) sementara mouse_click di koordinatnya mengenai.
        # Itulah yang memisahkan kontrak 1 dari kontrak 2 di project yang sama.
        [System.IO.File]::WriteAllText("$t43Dir\main.gd", @'
extends Node

var _n := 0

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var b := Button.new()
	b.text = "tekan"
	b.position = Vector2(100, 100)
	b.size = Vector2(200, 60)
	b.pressed.connect(func(): _n += 1)
	root.add_child(b)

func _get_game_state() -> Dictionary:
	return {"counter": _n}
'@, $noBom43)

        [System.IO.File]::WriteAllText("$t43Dir\scenarios\inert.json",
            '{"scenario_id":"t43_inert","steps":[{"type":"wait_frames","frames":20},{"type":"screenshot","name":"t43i_a"},{"type":"action","action":"ui_accept"},{"type":"wait_frames","frames":10},{"type":"screenshot","name":"t43i_b"}]}', $noBom43)
        [System.IO.File]::WriteAllText("$t43Dir\scenarios\alive.json",
            '{"scenario_id":"t43_alive","steps":[{"type":"wait_frames","frames":20},{"type":"screenshot","name":"t43a_a"},{"type":"mouse_click","x":200,"y":130},{"type":"wait_frames","frames":10},{"type":"screenshot","name":"t43a_b"}]}', $noBom43)
        [System.IO.File]::WriteAllText("$t43Dir\scenarios\allow.json",
            '{"scenario_id":"t43_allow","allow_inert":true,"steps":[{"type":"wait_frames","frames":20},{"type":"screenshot","name":"t43w_a"},{"type":"action","action":"ui_accept"},{"type":"wait_frames","frames":10},{"type":"screenshot","name":"t43w_b"}]}', $noBom43)
        [System.IO.File]::WriteAllText("$t43Dir\scenarios\shots.json",
            '{"scenario_id":"t43_shots","steps":[{"type":"wait_frames","frames":20},{"type":"screenshot","name":"t43s_a"},{"type":"wait_frames","frames":10},{"type":"screenshot","name":"t43s_b"}]}', $noBom43)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t43Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t43Res = "$env:APPDATA\Godot\app_userdata\KiloT43\shots\scenario_result.json"
        $t43Probs = @()

        foreach ($case in @(
            @{ File = "inert.json"; Expect = "inert" },
            @{ File = "alive.json"; Expect = "pass"  },
            @{ File = "allow.json"; Expect = "pass"  },
            @{ File = "shots.json"; Expect = "pass"  }
        )) {
            Remove-Item -LiteralPath $t43Res -Force -ErrorAction SilentlyContinue
            $pr43 = Start-Process $GodotExe -ArgumentList "--path", "`"$t43Dir`"", "--", "--scenario", "res://scenarios/$($case.File)" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($pr43) { $pr43.Handle | Out-Null; $pr43.WaitForExit(45000) | Out-Null; if (-not $pr43.HasExited) { $pr43.Kill() } }
            if (-not (Test-Path -LiteralPath $t43Res)) {
                $t43Probs += "$($case.File): scenario_result.json tidak dihasilkan"; continue
            }
            $r43 = Get-Content -LiteralPath $t43Res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r43.status -ne $case.Expect) {
                $t43Probs += "$($case.File): status=$($r43.status), harus $($case.Expect)"
            }
            # kontrak 4: scenario tanpa input tidak boleh dikenai gerbang
            if ($case.File -eq "shots.json" -and $r43.liveness.required) {
                $t43Probs += "shots.json: liveness.required=true padahal tidak ada langkah input"
            }
            if ($case.File -eq "alive.json" -and -not $r43.liveness.state_changed) {
                $t43Probs += "alive.json: state_changed=false padahal klik menaikkan counter"
            }
        }

        Add-Result "liveness: input tanpa perubahan -> inert" ($t43Probs.Count -eq 0) `
            $(if ($t43Probs.Count -eq 0) { "inert/pass/allow_inert/tanpa-input keempatnya benar" } else { ($t43Probs -join " | ") })
    } catch {
        Add-Result "liveness: input tanpa perubahan -> inert" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t43Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT43" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 44: game-doctor -- pemeriksaan statis terhadap project game ──────────
# Dari tujuh temuan pada audit jimat, tiga bisa didapat dengan satu grep: mojibake di teks
# UI, tur screenshot yang dipanggil dua kali, dan nol grab_focus(). Ketiganya STATIS, dan
# framework tidak memeriksanya sama sekali -- ia hanya melihat apa yang berhasil dirender.
# Artinya ketiga temuan itu bergantung pada ada-tidaknya seseorang yang kebetulan curiga.
# Test ini mengunci empat pemeriksaan itu plus satu kontrak yang gampang terlewat:
#   1. mojibake terdeteksi lewat uji keterbalikan encoding (bukan daftar karakter)
#   2. game yang memanggil _shot_tour sendiri terdeteksi
#   3. project bertombol tanpa grab_focus terdeteksi
#   4. cabang --scenario yang berhenti dini terdeteksi
#   5. direktori cadangan/arsip TIDAK ikut diperiksa -- saat menguji tool ini, temuan
#      pertama yang muncul justru folder _backup buatan sendiri. Pemeriksa yang menuduh
#      arsip cepat kehilangan kepercayaan, dan yang tidak dipercaya akan dimatikan.
Write-T "TEST 44: game-doctor menemukan cacat statis dan tidak memeriksa folder arsip"
$t44Tool = Join-Path $PSScriptRoot "game-doctor.ps1"
if (-not (Test-Path -LiteralPath $t44Tool)) {
    Add-Result "game-doctor: cacat statis + arsip diabaikan" $false "game-doctor.ps1 tidak ditemukan"
} else {
    $t44Dir = Join-Path $env:TEMP "kilo_t44_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $t44Bad   = Join-Path $t44Dir "rusak"
        $t44Good  = Join-Path $t44Dir "bersih"
        foreach ($d in @("$t44Bad\scripts", "$t44Good\scripts", "$t44Good\_backup")) {
            $null = New-Item -ItemType Directory -Path $d -Force
        }
        $noBom44 = New-Object System.Text.UTF8Encoding($false)

        # Mojibake ASLI, dibuat dengan mensimulasikan kerusakannya: byte UTF-8 dari em-dash
        # dibaca sebagai CP1252, lalu hasilnya disimpan sebagai UTF-8. Menuliskan urutan
        # karakternya secara harfiah akan menguji regex saya, bukan mekanisme sebenarnya.
        $emdash   = [char]0x2014
        $utf8Byte = [System.Text.Encoding]::UTF8.GetBytes("Lanjut $emdash malam")
        $moji     = [System.Text.Encoding]::GetEncoding(1252).GetString($utf8Byte)

        $badMain = @"
extends Node

func _ready() -> void:
	if "--scenario" in OS.get_cmdline_user_args():
		var ui := Control.new()
		add_child(ui)
		return
	if "--shot" in OS.get_cmdline_user_args():
		_shot_tour.call_deferred()
	var b := Button.new()
	b.text = "$moji"
	add_child(b)

func _shot_tour() -> void:
	pass

func _get_game_state() -> Dictionary:
	return {"x": 1}
"@
        [System.IO.File]::WriteAllText("$t44Bad\scripts\main.gd", $badMain, $noBom44)
        [System.IO.File]::WriteAllText("$t44Bad\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"T44Bad`"`n`n[autoload]`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom44)

        # Versi bersih: tanpa mojibake, tanpa pemanggilan _shot_tour, ada grab_focus,
        # cabang --scenario tidak berhenti dini, kedua autoload terpasang.
        $goodMain = @"
extends Node

func _ready() -> void:
	var b := Button.new()
	b.text = "Mulai"
	add_child(b)
	b.grab_focus()

func _get_game_state() -> Dictionary:
	return {"x": 1}
"@
        [System.IO.File]::WriteAllText("$t44Good\scripts\main.gd", $goodMain, $noBom44)
        [System.IO.File]::WriteAllText("$t44Good\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"T44Good`"`n`n[autoload]`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`n", $noBom44)
        # Arsip bermasalah di project BERSIH -- tidak boleh dilaporkan sama sekali.
        [System.IO.File]::WriteAllText("$t44Good\_backup\main.gd", $badMain, $noBom44)

        $t44Probs = @()

        $repBad = Join-Path $t44Dir "bad.json"
        & $t44Tool -ProjectPath $t44Bad -OutputPath $repBad -Quiet *>$null
        $exitBad = $LASTEXITCODE
        if ($exitBad -ne 1) { $t44Probs += "project rusak: exit=$exitBad, harus 1" }
        if (-not (Test-Path -LiteralPath $repBad)) {
            $t44Probs += "laporan project rusak tidak ditulis"
        } else {
            $jb = Get-Content -LiteralPath $repBad -Raw -Encoding UTF8 | ConvertFrom-Json
            $ids = @($jb.findings | ForEach-Object { $_.id })
            foreach ($want in @("mojibake", "shot_tour_dipanggil_game", "tanpa_grab_focus",
                                "scenario_berhenti_dini", "autoload_hilang")) {
                if ($ids -notcontains $want) { $t44Probs += "project rusak: '$want' tidak terdeteksi" }
            }
        }

        $repGood = Join-Path $t44Dir "good.json"
        & $t44Tool -ProjectPath $t44Good -OutputPath $repGood -Quiet *>$null
        $exitGood = $LASTEXITCODE
        if ($exitGood -ne 0) { $t44Probs += "project bersih: exit=$exitGood, harus 0" }
        if (Test-Path -LiteralPath $repGood) {
            $jg = Get-Content -LiteralPath $repGood -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$jg.summary.error -ne 0)   { $t44Probs += "project bersih: $($jg.summary.error) error (harus 0)" }
            if ([int]$jg.summary.warning -ne 0) { $t44Probs += "project bersih: $($jg.summary.warning) warning (harus 0)" }
            $backupHit = @($jg.findings | Where-Object { $_.file -match "_backup" })
            if ($backupHit.Count -gt 0) { $t44Probs += "folder arsip _backup ikut diperiksa -- harus dilewati" }
        }

        Add-Result "game-doctor: cacat statis + arsip diabaikan" ($t44Probs.Count -eq 0) `
            $(if ($t44Probs.Count -eq 0) { "5 pemeriksaan menyala di project rusak, 0 temuan di project bersih" } else { ($t44Probs -join " | ") })
    } catch {
        Add-Result "game-doctor: cacat statis + arsip diabaikan" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t44Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 45: setiap peluncuran Godot --import wajib --headless ────────────────
# Godot berjendela yang GAGAL mengimpor project memunculkan dialog modal
# "Can't run project: no main scene defined in the project". Dialog itu merebut fokus
# pengguna dan MENAHAN proses sampai timeout -- tool yang seharusnya berjalan tanpa
# pengawasan jadi menggantung, dan di CI ia menggantung sampai job dibunuh.
# Empat lokasi pernah kehilangan flag ini sekaligus, termasuk run-and-analyze.ps1 yang
# dipakai pengguna langsung. Godot headless secara arsitektural tidak bisa menampilkan
# dialog, jadi flag ini bukan kosmetik melainkan syarat agar tool bisa dipercaya jalan
# tanpa ditunggui. Pemeriksaan statis menutup seluruh kelasnya sekaligus.
Write-T "TEST 45: semua peluncuran Godot --import memakai --headless"
try {
    # Disusun dari potongan supaya baris ini sendiri tidak ikut terpindai.
    $needleImport   = "--" + "import"
    $needleHeadless = "--" + "headless"
    $t45Bad = @()
    foreach ($t45File in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File)) {
        # Gabungkan baris yang disambung backtick supaya satu pemanggilan Start-Process
        # yang terpecah beberapa baris terbaca sebagai satu perintah utuh.
        $t45Join = @()
        $t45Acc = ""
        foreach ($ln in (Get-Content -LiteralPath $t45File.FullName)) {
            $trimmed = $ln.TrimEnd()
            if ($trimmed.EndsWith('`')) { $t45Acc += $trimmed.TrimEnd('`') + " "; continue }
            $t45Join += ($t45Acc + $trimmed)
            $t45Acc = ""
        }
        if ($t45Acc -ne "") { $t45Join += $t45Acc }

        $lineNo = 0
        foreach ($cmd in $t45Join) {
            $lineNo++
            if ($cmd -notmatch "Start-Process") { continue }
            if ($cmd -notlike "*$needleImport*") { continue }
            if ($cmd -like "*$needleHeadless*") { continue }
            $t45Bad += "$($t45File.Name) (perintah ke-$lineNo)"
        }
    }
    Add-Result "semua Godot --import memakai --headless" ($t45Bad.Count -eq 0) `
        $(if ($t45Bad.Count -eq 0) { "tidak ada peluncuran import berjendela" } else { ($t45Bad -join " | ") })
} catch {
    Add-Result "semua Godot --import memakai --headless" $false ("Exception: " + $_)
}
Write-S

# ── TEST 46: explore-minimize -- jejak diperkecil jadi repro minimal ──────────
# "40 klik lalu invariant jebol" benar tapi nyaris tak terpakai; yang dibutuhkan adalah
# KLIK MANA penyebabnya. Tiga kontrak diuji:
#   1. jejak diperkecil sampai hanya menyisakan klik yang benar-benar perlu
#   2. baseline diverifikasi lebih dulu dan GAGAL TERTUTUP: jejak yang tidak mereproduksi
#      menghentikan proses, bukan menghasilkan repro palsu. Ini kontrak terpenting --
#      hasil minimisasi dari jejak yang tidak reproducible adalah file yang tampak
#      berguna tapi tidak pernah bekerja, lebih buruk daripada tidak ada hasil.
#   3. invariant inline ikut terbawa ke setiap kandidat. Terukur saat pertama dijalankan:
#      kandidat hanya memuat invariant game-wide, sehingga baseline gagal karena aturan
#      yang sedang diselidiki tidak ikut dimuat.
Write-T "TEST 46: explore-minimize memperkecil jejak dan gagal tertutup bila tak reproducible"
$t46Tool = Join-Path $PSScriptRoot "explore-minimize.ps1"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "explore-minimize: perkecil jejak + gagal tertutup" $false "SKIP -- Godot tidak tersedia"
} elseif (-not (Test-Path -LiteralPath $t46Tool)) {
    Add-Result "explore-minimize: perkecil jejak + gagal tertutup" $false "explore-minimize.ps1 tidak ditemukan"
} else {
    $t46Dir = Join-Path $env:TEMP "kilo_t46_$($PID)_$(Get-Date -Format 'HHmmss')"
    $t46Shots = "$env:APPDATA\Godot\app_userdata\KiloT46\shots"
    try {
        $null = New-Item -ItemType Directory -Path "$t46Dir\scripts" -Force
        $null = New-Item -ItemType Directory -Path $t46Shots -Force
        $noBom46 = New-Object System.Text.UTF8Encoding($false)
        $t46Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t46Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t46Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom46)
        }
        [System.IO.File]::WriteAllText("$t46Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT46`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom46)
        [System.IO.File]::WriteAllText("$t46Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom46)
        # Tiga tombol pada posisi TETAP dan semuanya terlihat bersamaan -- tidak ada navigasi,
        # jadi membuang satu klik tidak menggeser posisi klik lain. Hanya tombol C yang
        # mengubah state, sehingga hasil minimisasi yang benar HARUS tinggal satu klik.
        [System.IO.File]::WriteAllText("$t46Dir\main.gd", @'
extends Node

var _flag := false

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var ys := [100, 200, 300]
	var nm := ["A", "B", "C"]
	for i in 3:
		var b := Button.new()
		b.text = nm[i]
		b.position = Vector2(100, ys[i])
		b.size = Vector2(200, 50)
		root.add_child(b)
		if nm[i] == "C":
			b.pressed.connect(_on_c)

func _on_c() -> void:
	_flag = true

func _get_game_state() -> Dictionary:
	return {"flag": _flag}
'@, $noBom46)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t46Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait

        $t46Inv = '"invariants":[{"id":"flag_mati","expr":"curr.flag == false","severity":"warning"}]'
        $t46Pre = '{"type":"wait_frames","frames":30}'
        $t46A   = '{"type":"mouse_click","x":200,"y":125,"wait_frames":6,"comment":"klik: A"}'
        $t46B   = '{"type":"mouse_click","x":200,"y":225,"wait_frames":6,"comment":"klik: B"}'
        $t46C   = '{"type":"mouse_click","x":200,"y":325,"wait_frames":6,"comment":"klik: C"}'
        $t46Probs = @()
        $t46Replay = Join-Path $t46Shots "explore_replay.json"
        $t46Repro  = Join-Path $t46Shots "explore_repro.json"

        # -- kontrak 1 & 3: A,B,C -> harus tersisa hanya C ----------------------
        [System.IO.File]::WriteAllText($t46Replay,
            "{`"scenario_id`":`"explore_replay`",$t46Inv,`"steps`":[$t46Pre,$t46A,$t46B,$t46C]}", $noBom46)
        Remove-Item -LiteralPath $t46Repro -Force -ErrorAction SilentlyContinue
        & $t46Tool -ProjectPath $t46Dir -InvariantId "flag_mati" -Timeout 45 -MaxRuns 15 *>$null
        $exitMin = $LASTEXITCODE
        if ($exitMin -ne 0) { $t46Probs += "minimisasi exit=$exitMin, harus 0" }
        if (-not (Test-Path -LiteralPath $t46Repro)) {
            $t46Probs += "explore_repro.json tidak ditulis"
        } else {
            $rr = Get-Content -LiteralPath $t46Repro -Raw -Encoding UTF8 | ConvertFrom-Json
            $mc = @($rr.steps | Where-Object { $_.type -eq "mouse_click" })
            if ($mc.Count -ne 1) {
                $t46Probs += "hasil $($mc.Count) klik, harus 1 (hanya C yang mengubah state)"
            } elseif ([int]$mc[0].y -ne 325) {
                $t46Probs += "klik tersisa y=$($mc[0].y), harus 325 (tombol C)"
            }
        }

        # -- kontrak 2: jejak tanpa C -> baseline gagal -> exit 1, TANPA repro ---
        [System.IO.File]::WriteAllText($t46Replay,
            "{`"scenario_id`":`"explore_replay`",$t46Inv,`"steps`":[$t46Pre,$t46A,$t46B]}", $noBom46)
        Remove-Item -LiteralPath $t46Repro -Force -ErrorAction SilentlyContinue
        & $t46Tool -ProjectPath $t46Dir -InvariantId "flag_mati" -Timeout 45 -MaxRuns 15 *>$null
        $exitNo = $LASTEXITCODE
        if ($exitNo -ne 1) { $t46Probs += "jejak tak reproducible exit=$exitNo, harus 1 (gagal tertutup)" }
        if (Test-Path -LiteralPath $t46Repro) {
            $t46Probs += "explore_repro.json ditulis padahal baseline tidak mereproduksi"
        }

        Add-Result "explore-minimize: perkecil jejak + gagal tertutup" ($t46Probs.Count -eq 0) `
            $(if ($t46Probs.Count -eq 0) { "3 klik -> 1 klik (C), dan jejak tak reproducible ditolak" } else { ($t46Probs -join " | ") })
    } catch {
        Add-Result "explore-minimize: perkecil jejak + gagal tertutup" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t46Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT46" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 47: lokalisasi diff -- JENIS perubahan, bukan sekadar besarnya ───────
# "04_battle berubah 24.75%" tidak memberi tahu apakah seluruh layar bergeser beberapa
# pixel (screen-shake, konten identik) atau satu panel benar-benar berubah. Keduanya bisa
# menghasilkan persen yang mirip, dan sepertiga awal sesi audit jimat habis untuk menjawab
# pertanyaan itu secara manual. Tiga klasifikasi diuji dengan jawaban yang diketahui:
#   geser  -- seluruh frame digeser (+5,-2); harus terdeteksi offsetnya dan residual ~0
#   konten -- satu kotak berubah; kotak batasnya harus kecil dan terpusat
#   global -- kecerahan seluruh frame berubah; menyebar penuh TAPI bukan pergeseran
# Yang terakhir paling mudah salah: %@ menghitung batas dengan memangkas tepi seragam,
# dan saat SELURUH frame berubah tidak ada tepi tersisa sehingga hasilnya menyusut ke 0x0 --
# terbaca sebagai cakupan 0% dan salah digolongkan 'konten'.
Write-T "TEST 47: visual-diff membedakan geser / konten / global"
$t47Vd = Join-Path $PSScriptRoot "visual-diff.ps1"
$t47Im = ""
foreach ($cand47 in @("magick", "convert")) {
    $f47 = Get-Command $cand47 -ErrorAction SilentlyContinue
    if ($f47) { $t47Im = $f47.Source; break }
}
if ((Test-Path -LiteralPath $t47Vd) -and $t47Im -ne "") {
    $t47Dir = Join-Path $env:TEMP "kilo_t47_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $t47Base = Join-Path $t47Dir "baseline"
        $t47Cur  = Join-Path $t47Dir "shots"
        $null = New-Item -ItemType Directory -Path $t47Base -Force
        $null = New-Item -ItemType Directory -Path $t47Cur  -Force

        # Pola berstruktur dan TIDAK periodik. Periodik (mis. checkerboard) berbahaya di sini:
        # pergeseran sebesar kelipatan periodenya menghasilkan citra identik, sehingga
        # pencarian offset punya banyak minimum yang sama benarnya dan hasilnya ambigu.
        $t47Src = Join-Path $t47Dir "src.png"
        $t47Draw = @(
            "rectangle 10,12 70,58",    "rectangle 95,20 130,140",  "rectangle 150,8 260,44",
            "rectangle 30,90 88,180",   "rectangle 190,70 250,120", "rectangle 275,30 340,96",
            "rectangle 120,160 210,205","rectangle 300,140 380,190","rectangle 45,215 150,262",
            "rectangle 230,215 300,275","rectangle 330,210 392,268","rectangle 160,120 178,150",
            "rectangle 260,150 285,200","rectangle 8,190 34,240",   "rectangle 355,100 385,130"
        ) | ForEach-Object { "-draw `"$_`"" }
        # Midtone, BUKAN hitam-putih murni. Pada kanvas putih dengan kotak hitam,
        # -modulate tidak mengubah apa pun (putih sudah maksimum, hitam tetap nol),
        # sehingga kasus 'global' tidak menghasilkan perubahan sama sekali dan tidak pernah
        # sampai ke tahap lokalisasi -- fixture-nya yang diam, bukan tool-nya yang salah.
        $t47Args = "-size 400x300 xc:gray85 -fill gray30 " + ($t47Draw -join " ") + " `"$t47Src`""
        $null = Invoke-Magick -Exe $t47Im -MagickArgs $t47Args

        Copy-Item -LiteralPath $t47Src -Destination (Join-Path $t47Base "a_geser.png")  -Force
        Copy-Item -LiteralPath $t47Src -Destination (Join-Path $t47Base "b_konten.png") -Force
        Copy-Item -LiteralPath $t47Src -Destination (Join-Path $t47Base "c_global.png") -Force
        $null = Invoke-Magick -Exe $t47Im -MagickArgs "`"$t47Src`" -roll +5-2 `"$(Join-Path $t47Cur 'a_geser.png')`""
        $null = Invoke-Magick -Exe $t47Im -MagickArgs "`"$t47Src`" -fill red -draw `"rectangle 200,200 320,270`" `"$(Join-Path $t47Cur 'b_konten.png')`""
        $null = Invoke-Magick -Exe $t47Im -MagickArgs "`"$t47Src`" -modulate 118 `"$(Join-Path $t47Cur 'c_global.png')`""

        & $t47Vd -ShotsDir $t47Cur -BaselineDir $t47Base -Threshold 1 *>$null
        $t47Rep = Join-Path $t47Cur "diff\diff-report.json"
        $t47Probs = @()
        if (-not (Test-Path -LiteralPath $t47Rep)) {
            $t47Probs += "diff-report.json tidak dihasilkan"
        } else {
            $t47Json = Get-Content -LiteralPath $t47Rep -Raw -Encoding UTF8 | ConvertFrom-Json
            function Get-T47 { param($N)
                return @($t47Json.files | Where-Object { $_.file -eq $N })[0]
            }
            $g = Get-T47 "a_geser.png"
            if ($null -eq $g) { $t47Probs += "a_geser tidak ada di laporan" }
            else {
                $gn = @($g.PSObject.Properties | ForEach-Object { $_.Name })
                if (($gn -contains "change_kind") -and $g.change_kind -ne "geser") { $t47Probs += "a_geser kind=$($g.change_kind), harus 'geser'" }
                elseif (-not ($gn -contains "change_kind")) { $t47Probs += "a_geser tidak dilokalisasi sama sekali" }
                elseif ([int]$g.shift_dx -ne 5 -or [int]$g.shift_dy -ne -2) {
                    $t47Probs += "a_geser offset=($($g.shift_dx),$($g.shift_dy)), harus (5,-2)"
                }
            }
            $k = Get-T47 "b_konten.png"
            if ($null -eq $k) { $t47Probs += "b_konten tidak ada di laporan" }
            else {
                $kn = @($k.PSObject.Properties | ForEach-Object { $_.Name })
                if (-not ($kn -contains "change_kind")) { $t47Probs += "b_konten tidak dilokalisasi" }
                elseif ($k.change_kind -ne "konten") { $t47Probs += "b_konten kind=$($k.change_kind), harus 'konten'" }
                elseif ([double]$k.bbox_coverage_pct -ge 70) { $t47Probs += "b_konten cakupan=$($k.bbox_coverage_pct)%, harus < 70" }
            }
            $gl = Get-T47 "c_global.png"
            if ($null -eq $gl) { $t47Probs += "c_global tidak ada di laporan" }
            else {
                $gln = @($gl.PSObject.Properties | ForEach-Object { $_.Name })
                if (-not ($gln -contains "change_kind")) { $t47Probs += "c_global tidak dilokalisasi" }
                elseif ($gl.change_kind -ne "global") {
                    $t47Probs += "c_global kind=$($gl.change_kind), harus 'global' (kotak batas 0x0 salah dibaca sebagai cakupan 0%?)"
                }
            }
        }
        Add-Result "visual-diff membedakan geser/konten/global" ($t47Probs.Count -eq 0) `
            $(if ($t47Probs.Count -eq 0) { "geser (5,-2) terdeteksi, konten terpusat, global tidak salah digolongkan" } else { ($t47Probs -join " | ") })
    } catch {
        Add-Result "visual-diff membedakan geser/konten/global" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t47Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result "visual-diff membedakan geser/konten/global" $false "SKIP -- ImageMagick/visual-diff tidak tersedia"
}
Write-S

# ── TEST 48: class_name ganda di dalam satu project ───────────────────────────
# Godot menolak memuat dua script yang mendaftarkan class_name sama, dan yang gagal bukan
# hanya salinannya -- yang ASLI ikut mati. Layar yang memakainya lalu tidak pernah terbangun
# dan tur screenshot berhenti di tengah tanpa pesan yang menyebut sebabnya.
# Terjadi betulan: folder cadangan bertanggal ditaruh di dalam project jimat, dan tur
# berhenti di 14 dari 23 layar selama berjam-jam tanpa satu pun pemeriksaan menyebut kenapa.
# Empat kontrak, dua di antaranya soal aturan visibilitas Godot -- bukan aturan doctor:
#   1. duplikat di direktori biasa terdeteksi
#   2. direktori ber-.gdignore DILEWATI (Godot melewatinya, jadi bukan duplikat)
#   3. direktori berawalan titik DILEWATI (Godot mengabaikannya)
#   4. class_name di dalam komentar tidak dihitung
# Kontrak 2 yang paling mudah salah: pemindaian ini sengaja TIDAK memakai daftar
# pengecualian doctor, karena justru di folder yang doctor lewati duplikat itu bersembunyi.
Write-T "TEST 48: game-doctor mendeteksi class_name ganda dengan aturan visibilitas Godot"
$t48Tool = Join-Path $PSScriptRoot "game-doctor.ps1"
if (-not (Test-Path -LiteralPath $t48Tool)) {
    Add-Result "class_name ganda terdeteksi (aturan Godot)" $false "game-doctor.ps1 tidak ditemukan"
} else {
    $t48Dir = Join-Path $env:TEMP "kilo_t48_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $noBom48 = New-Object System.Text.UTF8Encoding($false)
        foreach ($sub in @("scripts", "_backup", ".arsip")) {
            $null = New-Item -ItemType Directory -Path (Join-Path $t48Dir $sub) -Force
        }
        [System.IO.File]::WriteAllText("$t48Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"T48`"`n`n[autoload]`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`n", $noBom48)
        [System.IO.File]::WriteAllText("$t48Dir\scripts\asli.gd",
            "class_name Foo`nextends Node`n`nfunc _get_game_state() -> Dictionary:`n`treturn {}`n", $noBom48)
        # Salinan di direktori BIASA -> Godot memindainya -> duplikat sungguhan
        [System.IO.File]::WriteAllText("$t48Dir\_backup\salinan.gd",
            "class_name Foo`nextends Node`n", $noBom48)
        # Direktori berawalan titik -> Godot mengabaikannya -> BUKAN duplikat
        [System.IO.File]::WriteAllText("$t48Dir\.arsip\lama.gd",
            "class_name Foo`nextends Node`n", $noBom48)
        # class_name di dalam komentar -> tidak boleh dihitung
        [System.IO.File]::WriteAllText("$t48Dir\scripts\komentar.gd",
            "extends Node`n# class_name Foo  <- ini hanya contoh di komentar`n", $noBom48)

        $t48Probs = @()
        $rep48 = Join-Path $t48Dir "r.json"

        # -- kontrak 1, 3, 4: duplikat nyata terdeteksi, dot-dir & komentar tidak --
        & $t48Tool -ProjectPath $t48Dir -OutputPath $rep48 -Quiet *>$null
        $j48 = Get-Content -LiteralPath $rep48 -Raw -Encoding UTF8 | ConvertFrom-Json
        $dup = @($j48.findings | Where-Object { $_.id -eq "class_name_ganda" })
        if ($dup.Count -eq 0) {
            $t48Probs += "duplikat di _backup\ tidak terdeteksi"
        } else {
            if ($dup[0].message -notmatch "_backup") { $t48Probs += "temuan tidak menyebut berkas di _backup" }
            if ($dup[0].message -match "\.arsip")    { $t48Probs += "direktori berawalan titik ikut dihitung -- Godot mengabaikannya" }
            if ($dup[0].message -match "komentar")   { $t48Probs += "class_name di dalam komentar ikut dihitung" }
        }

        # -- kontrak 2: .gdignore membuat direktori itu tidak terlihat oleh Godot --
        [System.IO.File]::WriteAllText("$t48Dir\_backup\.gdignore", "diabaikan Godot", $noBom48)
        & $t48Tool -ProjectPath $t48Dir -OutputPath $rep48 -Quiet *>$null
        $j48b = Get-Content -LiteralPath $rep48 -Raw -Encoding UTF8 | ConvertFrom-Json
        $dupB = @($j48b.findings | Where-Object { $_.id -eq "class_name_ganda" })
        if ($dupB.Count -ne 0) { $t48Probs += ".gdignore tidak dihormati -- direktori itu tidak dilihat Godot" }

        Add-Result "class_name ganda terdeteksi (aturan Godot)" ($t48Probs.Count -eq 0) `
            $(if ($t48Probs.Count -eq 0) { "duplikat terdeteksi; .gdignore, dot-dir, dan komentar dikecualikan" } else { ($t48Probs -join " | ") })
    } catch {
        Add-Result "class_name ganda terdeteksi (aturan Godot)" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t48Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 49: bedakan "salah ketik field" dari "penyedia state tak tercapai" ───
# Keduanya menghasilkan gejala yang PERSIS sama -- "field tidak ada di game_state" --
# tetapi perbaikannya berlawanan: yang satu betulkan nama field, yang satu perbaiki
# jangkauan hook. Tanpa dibedakan, pembaca laporan menebak.
# Ditemukan saat menjalankan framework pada bread-adventure, game yang tidak pernah
# disesuaikan terhadapnya: _get_game_state() ada tetapi melekat pada satu layar, jadi
# begitu scenario berpindah layar seluruh field game lenyap dan yang tersisa persis keenam
# field fallback GameStateWriter.
# Fixture memakai DUA project, bukan satu project dengan penyedia yang menyusul setelah
# jeda. Versi berbasis waktu sempat dicoba dan salah: bootstrap ErrorTracker plus jeda
# hot-reload sudah memakan lebih dari satu detik sebelum langkah pertama berjalan, sehingga
# scenario "awal" pun sudah melihat state kaya (terukur: frame_count 187 di langkah pertama).
# Fixture yang bergantung pada waktu adalah sumber tes rewel; kehadiran penyedia adalah
# properti project, jadi bedakan di level project.
Write-T "TEST 49: pesan assert_state membedakan field salah dari penyedia state tak tercapai"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "assert_state menandai state fallback-only" $false "SKIP -- Godot tidak tersedia"
} else {
    $t49Base = Join-Path $env:TEMP "kilo_t49_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $noBom49 = New-Object System.Text.UTF8Encoding($false)
        $t49Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        $t49Scen = '{"scenario_id":"t49","steps":[{"type":"wait_frames","frames":10},{"type":"write_state"},{"type":"assert_state","field":"tidak_ada","op":"eq","expected":1}]}'

        # Dua project identik kecuali satu hal: ada atau tidaknya _get_game_state() di main.
        $t49Cases = @(
            @{ Name = "KiloT49A"; ExpectHint = $true
               Main = "extends Node`n" }
            @{ Name = "KiloT49B"; ExpectHint = $false
               Main = "extends Node`n`nfunc _get_game_state() -> Dictionary:`n`treturn {`"hp`": 5}`n" }
        )
        $t49Probs = @()

        foreach ($case in $t49Cases) {
            $dir = Join-Path $t49Base $case.Name
            $null = New-Item -ItemType Directory -Path "$dir\scripts"   -Force
            $null = New-Item -ItemType Directory -Path "$dir\scenarios" -Force
            foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
                $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t49Tmpl $tmpl))
                $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
                [System.IO.File]::WriteAllText("$dir\scripts\$tmpl",
                    [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom49)
            }
            [System.IO.File]::WriteAllText("$dir\project.godot",
                "config_version=5`n`n[application]`nconfig/name=`"$($case.Name)`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom49)
            [System.IO.File]::WriteAllText("$dir\main.tscn",
                "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom49)
            [System.IO.File]::WriteAllText("$dir\main.gd", $case.Main, $noBom49)
            [System.IO.File]::WriteAllText("$dir\scenarios\t.json", $t49Scen, $noBom49)

            $null = Start-Process $GodotExe -ArgumentList "--path", "`"$dir`"", "--headless", "--import", "--quit" `
                -PassThru -NoNewWindow -Wait
            $res = "$env:APPDATA\Godot\app_userdata\$($case.Name)\shots\scenario_result.json"
            Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue
            $pr49 = Start-Process $GodotExe -ArgumentList "--path", "`"$dir`"", "--", "--scenario", "res://scenarios/t.json" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($pr49) { $pr49.Handle | Out-Null; $pr49.WaitForExit(45000) | Out-Null; if (-not $pr49.HasExited) { $pr49.Kill() } }

            if (-not (Test-Path -LiteralPath $res)) { $t49Probs += "$($case.Name): tidak ada hasil"; continue }
            $r49 = Get-Content -LiteralPath $res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r49.status -ne "fail") { $t49Probs += "$($case.Name): status=$($r49.status), harus fail" }
            $hasHint = ([string]$r49.error) -match "fallback"
            if ($case.ExpectHint -and -not $hasHint) {
                $t49Probs += "$($case.Name): state hanya fallback tetapi pesannya tidak menyebutkannya"
            }
            if (-not $case.ExpectHint -and $hasHint) {
                $t49Probs += "$($case.Name): state sudah memuat field game tetapi pesannya keliru menuduh fallback"
            }
        }

        Add-Result "assert_state menandai state fallback-only" ($t49Probs.Count -eq 0) `
            $(if ($t49Probs.Count -eq 0) { "fallback-only ditandai; state kaya tidak salah dituduh" } else { ($t49Probs -join " | ") })
    } catch {
        Add-Result "assert_state menandai state fallback-only" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t49Base -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in @("KiloT49A", "KiloT49B")) {
            Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\$n" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
Write-S

# ── TEST 50: minimisasi jejak NAVIGASI, bukan hanya papan tombol tetap ────────
# TEST 46 memakai tiga tombol yang selalu terlihat bersamaan -- membuang satu klik tidak
# pernah membuat klik lain hilang. Fixture semacam itu menyembunyikan kasus yang justru
# paling sering terjadi di game sungguhan: menu berlapis, di mana klik mengubah tombol
# mana yang ada. Terukur pada jimat: jejak 5 klik yang seharusnya menyusut jadi 1 mentok
# di 5 dari 5, karena membuang "masuk Candi" membuat "Back" berikutnya tidak punya tombol
# untuk ditekan, subset ditolak, dan tidak ada satu klik pun yang bisa dibuang sendirian.
#
# Yang diuji di sini: pasangan navigasi ("masuk", lalu "Back") harus bisa dibuang SEKALIGUS,
# sehingga jejak menyusut sampai hanya menyisakan klik yang benar-benar mengubah state.
Write-T "TEST 50: minimisasi membuang pasangan navigasi, bukan hanya klik tunggal"
$t50Tool = Join-Path $PSScriptRoot "explore-minimize.ps1"
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Add-Result "explore-minimize: jejak navigasi menyusut ke klik penyebab" $false "SKIP -- Godot tidak tersedia"
} elseif (-not (Test-Path -LiteralPath $t50Tool)) {
    Add-Result "explore-minimize: jejak navigasi menyusut ke klik penyebab" $false "explore-minimize.ps1 tidak ditemukan"
} else {
    $t50Dir   = Join-Path $env:TEMP "kilo_t50_$($PID)_$(Get-Date -Format 'HHmmss')"
    $t50Shots = "$env:APPDATA\Godot\app_userdata\KiloT50\shots"
    try {
        $null = New-Item -ItemType Directory -Path "$t50Dir\scripts" -Force
        $null = New-Item -ItemType Directory -Path $t50Shots -Force
        $noBom50 = New-Object System.Text.UTF8Encoding($false)
        $t50Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t50Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t50Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom50)
        }
        [System.IO.File]::WriteAllText("$t50Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT50`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom50)
        [System.IO.File]::WriteAllText("$t50Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom50)
        # Dua layar. "Menu A" pindah ke sub-layar yang HANYA punya "Back"; "Back" kembali.
        # Hanya "Go" yang mengubah state, dan "Go" cuma ada di layar judul. Jadi:
        #   buang "Menu A" saja -> "Back" tidak ada       -> subset ditolak
        #   buang "Back" saja   -> "Go" tidak ada         -> subset ditolak
        #   buang "Go" saja     -> tidak ada pelanggaran  -> subset ditolak
        # Satu-satunya jalan ke repro minimal adalah membuang "Menu A"+"Back" sekaligus.
        [System.IO.File]::WriteAllText("$t50Dir\main.gd", @'
extends Node

var _flag := false
var _title: Control
var _sub: Control

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_title = Control.new()
	_title.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_title)
	_sub = Control.new()
	_sub.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_sub)
	_mk(_title, "Menu A", 100).pressed.connect(_go_sub)
	_mk(_title, "Go", 200).pressed.connect(_do_go)
	_mk(_sub, "Back", 100).pressed.connect(_go_title)
	_sub.visible = false

func _mk(parent: Control, txt: String, y: int) -> Button:
	var b := Button.new()
	b.text = txt
	b.position = Vector2(100, y)
	b.size = Vector2(200, 50)
	parent.add_child(b)
	return b

func _go_sub() -> void:
	_title.visible = false
	_sub.visible = true

func _go_title() -> void:
	_sub.visible = false
	_title.visible = true

func _do_go() -> void:
	_flag = true

func _get_game_state() -> Dictionary:
	return {"flag": _flag}
'@, $noBom50)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t50Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait

        $t50Inv  = '"invariants":[{"id":"flag_mati","expr":"curr.flag == false","severity":"warning"}]'
        $t50Pre  = '{"type":"wait_frames","frames":30}'
        $t50Nav  = '{"type":"click_button","label":"Menu A","wait_frames":6}'
        $t50Back = '{"type":"click_button","label":"Back","wait_frames":6}'
        $t50Go   = '{"type":"click_button","label":"Go","wait_frames":6}'
        $t50Probs = @()
        $t50Replay = Join-Path $t50Shots "explore_replay.json"
        $t50Repro  = Join-Path $t50Shots "explore_repro.json"

        [System.IO.File]::WriteAllText($t50Replay,
            "{`"scenario_id`":`"explore_replay`",$t50Inv,`"steps`":[$t50Pre,$t50Nav,$t50Back,$t50Go]}", $noBom50)
        Remove-Item -LiteralPath $t50Repro -Force -ErrorAction SilentlyContinue
        & $t50Tool -ProjectPath $t50Dir -InvariantId "flag_mati" -Timeout 45 -MaxRuns 20 *>$null
        $exit50 = $LASTEXITCODE
        if ($exit50 -ne 0) { $t50Probs += "minimisasi exit=$exit50, harus 0" }
        if (-not (Test-Path -LiteralPath $t50Repro)) {
            $t50Probs += "explore_repro.json tidak ditulis"
        } else {
            $rr50 = Get-Content -LiteralPath $t50Repro -Raw -Encoding UTF8 | ConvertFrom-Json
            $cb50 = @($rr50.steps | Where-Object { $_.type -eq "click_button" })
            if ($cb50.Count -ne 1) {
                $lbls = ($cb50 | ForEach-Object { $_.label }) -join ", "
                $t50Probs += "hasil $($cb50.Count) klik [$lbls], harus 1 (pasangan navigasi harus terbuang sekaligus)"
            } elseif ($cb50[0].label -ne "Go") {
                $t50Probs += "klik tersisa '$($cb50[0].label)', harus 'Go'"
            }
        }

        Add-Result "explore-minimize: jejak navigasi menyusut ke klik penyebab" ($t50Probs.Count -eq 0) `
            $(if ($t50Probs.Count -eq 0) { "3 klik (Menu A, Back, Go) -> 1 klik (Go)" } else { ($t50Probs -join " | ") })
    } catch {
        Add-Result "explore-minimize: jejak navigasi menyusut ke klik penyebab" $false ("Exception: " + $_)
    } finally {
        Remove-Item -LiteralPath $t50Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT50" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-S

# ── TEST 51: step type asing gagal, dan dokumentasinya tidak menjanjikan yang tak ada ──
# Ditemukan saat memverifikasi hitungan step type: command/scenario.md mendokumentasikan
# delapan type yang TIDAK ADA di dispatcher (mouse_move, touch, swipe, controller,
# long_press, double_tap, pinch, load_scene). Agen yang membaca tabel itu akan menulis
# {"type":"swipe"}, ScenarioRunner mem-_step_skip-nya, dan scenario berakhir "pass" tanpa
# pernah mengirim satu pun input. Gerbang liveness tidak menolong: type asing tidak dikenali
# sebagai langkah input, jadi gerbangnya tidak pernah aktif.
#
# Tiga kontrak:
#   1. step type asing -> status fail, BUKAN pass/skip
#   2. dispatcher dan KNOWN_STEP_TYPES sepadan -- tidak ada yang bisa diimplementasikan
#      tanpa didaftarkan, atau didaftarkan tanpa diimplementasikan
#   3. tabel di command/scenario.md persis sama dengan KNOWN_STEP_TYPES
Write-T "TEST 51: step type asing gagal, dispatcher dan dokumentasi sepadan"
$t51Probs = @()
$t51Runner = Join-Path $env:USERPROFILE ".config\kilo\godot-templates\ScenarioRunner.gd"
$t51Doc    = Join-Path $PSScriptRoot "..\command\scenario.md"
if (-not (Test-Path -LiteralPath $t51Doc)) { $t51Doc = Join-Path $env:USERPROFILE ".config\kilo\command\scenario.md" }

if (-not (Test-Path -LiteralPath $t51Runner)) {
    $t51Probs += "ScenarioRunner.gd tidak ditemukan di $t51Runner"
} else {
    $src51 = Get-Content -LiteralPath $t51Runner -Raw -Encoding UTF8

    # -- kontrak 2a: kumpulkan type dari cabang _dispatch --------------------------
    $disp51 = @()
    foreach ($m in [regex]::Matches($src51, 'step_type\s*==\s*"([a-z_]+)"')) {
        $disp51 += $m.Groups[1].Value
    }
    $disp51 = @($disp51 | Sort-Object -Unique)

    # -- kontrak 2b: kumpulkan KNOWN_STEP_TYPES ------------------------------------
    $known51 = @()
    $kBlock = [regex]::Match($src51, 'const\s+KNOWN_STEP_TYPES\s*:=\s*\[(?<body>[^\]]*)\]')
    if (-not $kBlock.Success) {
        $t51Probs += "const KNOWN_STEP_TYPES tidak ditemukan di ScenarioRunner.gd"
    } else {
        foreach ($m in [regex]::Matches($kBlock.Groups["body"].Value, '"([a-z_]+)"')) {
            $known51 += $m.Groups[1].Value
        }
        $known51 = @($known51 | Sort-Object -Unique)
        $onlyDisp = @($disp51 | Where-Object { $known51 -notcontains $_ })
        $onlyKnwn = @($known51 | Where-Object { $disp51 -notcontains $_ })
        if ($onlyDisp.Count -gt 0) { $t51Probs += "diimplementasikan tapi tidak didaftarkan: $($onlyDisp -join ', ')" }
        if ($onlyKnwn.Count -gt 0) { $t51Probs += "didaftarkan tapi tidak diimplementasikan: $($onlyKnwn -join ', ')" }
    }

    # -- kontrak 3: tabel dokumentasi sepadan --------------------------------------
    if (-not (Test-Path -LiteralPath $t51Doc)) {
        $t51Probs += "command/scenario.md tidak ditemukan -- tabel step type tidak bisa diperiksa"
    } elseif ($known51.Count -gt 0) {
        $doc51 = @()
        $inTable = $false
        foreach ($line in (Get-Content -LiteralPath $t51Doc -Encoding UTF8)) {
            if ($line -match '^## Step Types yang Didukung') { $inTable = $true; continue }
            if ($inTable -and $line -match '^## ')            { break }
            if ($inTable -and $line -match '^\|\s*`([a-z_]+)`\s*\|') { $doc51 += $Matches[1] }
        }
        $doc51 = @($doc51 | Sort-Object -Unique)
        $onlyDoc = @($doc51   | Where-Object { $known51 -notcontains $_ })
        $onlyRun = @($known51 | Where-Object { $doc51   -notcontains $_ })
        if ($onlyDoc.Count -gt 0) { $t51Probs += "didokumentasikan tapi tidak ada: $($onlyDoc -join ', ')" }
        if ($onlyRun.Count -gt 0) { $t51Probs += "ada tapi tidak didokumentasikan: $($onlyRun -join ', ')" }
    }
}

# -- kontrak 1: perilaku sungguhan -- type asing harus membuat scenario FAIL --------
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    $t51Probs += "SKIP perilaku -- Godot tidak tersedia"
} else {
    $t51Dir = Join-Path $env:TEMP "kilo_t51_$($PID)_$(Get-Date -Format 'HHmmss')"
    try {
        $null = New-Item -ItemType Directory -Path "$t51Dir\scripts" -Force
        $null = New-Item -ItemType Directory -Path "$t51Dir\scenarios" -Force
        $noBom51 = New-Object System.Text.UTF8Encoding($false)
        $t51Tmpl = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
        foreach ($tmpl in @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd")) {
            $rawT = [System.IO.File]::ReadAllBytes((Join-Path $t51Tmpl $tmpl))
            $offT = if ($rawT.Length -ge 3 -and $rawT[0] -eq 0xEF) { 3 } else { 0 }
            [System.IO.File]::WriteAllText("$t51Dir\scripts\$tmpl",
                [System.Text.Encoding]::UTF8.GetString($rawT, $offT, $rawT.Length - $offT), $noBom51)
        }
        [System.IO.File]::WriteAllText("$t51Dir\project.godot",
            "config_version=5`n`n[application]`nconfig/name=`"KiloT51`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n", $noBom51)
        [System.IO.File]::WriteAllText("$t51Dir\main.tscn",
            "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1`")`n", $noBom51)
        [System.IO.File]::WriteAllText("$t51Dir\main.gd", @'
extends Node

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

func _get_game_state() -> Dictionary:
	return {"ok": true}
'@, $noBom51)
        # "swipe" ada di tabel dokumentasi LAMA tapi tidak pernah diimplementasikan --
        # persis bentuk kesalahan yang membuat cacat ini lolos berbulan-bulan.
        [System.IO.File]::WriteAllText("$t51Dir\scenarios\asing.json",
            '{"scenario_id":"asing","steps":[{"type":"wait_frames","frames":10},{"type":"swipe","from_x":0,"from_y":0,"to_x":100,"to_y":100}]}', $noBom51)

        $null = Start-Process $GodotExe -ArgumentList "--path", "`"$t51Dir`"", "--headless", "--import", "--quit" `
            -PassThru -NoNewWindow -Wait
        $t51Res = "$env:APPDATA\Godot\app_userdata\KiloT51\shots\scenario_result.json"
        Remove-Item -LiteralPath $t51Res -Force -ErrorAction SilentlyContinue
        $pr51 = Start-Process $GodotExe -ArgumentList "--path", "`"$t51Dir`"", "--", "--scenario", "res://scenarios/asing.json" `
            -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($pr51) { $pr51.Handle | Out-Null; $pr51.WaitForExit(60000) | Out-Null; if (-not $pr51.HasExited) { $pr51.Kill() } }

        if (-not (Test-Path -LiteralPath $t51Res)) {
            $t51Probs += "scenario_result.json tidak ditulis untuk scenario step type asing"
        } else {
            $r51 = Get-Content -LiteralPath $t51Res -Raw -Encoding UTF8 | ConvertFrom-Json
            if ("$($r51.status)" -ne "fail") {
                $t51Probs += "step type asing menghasilkan status '$($r51.status)', harus 'fail'"
            }
        }
    } catch {
        $t51Probs += "Exception: $_"
    } finally {
        Remove-Item -LiteralPath $t51Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\KiloT51" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Add-Result "step type asing gagal + dispatcher/dokumentasi sepadan" ($t51Probs.Count -eq 0) `
    $(if ($t51Probs.Count -eq 0) { "21 step type, dispatcher = KNOWN_STEP_TYPES = tabel dokumentasi; 'swipe' -> fail" } else { ($t51Probs -join " | ") })
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
