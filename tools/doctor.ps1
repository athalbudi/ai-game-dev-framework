<#
.SYNOPSIS
    Healthcheck ringan untuk instalasi Saksi.
    Dipakai oleh setup.ps1 sebelum dan sesudah sync -- juga bisa dijalankan manual.

.DESCRIPTION
    Verifikasi murah dan cepat (BUKAN regresi penuh seperti test-pipeline.ps1 --
    itu tool maintainer dengan 19 section termasuk drift-check ke game validasi
    spesifik mesin dev, tidak relevan untuk pengguna baru):
      1. SEMUA tools/*.ps1 AST-parse bersih                      (CRITICAL)
      2. Godot terdeteksi + versi 4.x                            (WARN saja)
      3. Semua .gd di godot-templates/ + game-state-templates/
         compile bersih di Godot vanilla DAN strict mode         (CRITICAL, hanya jika Godot ada)
      4. ImageMagick terdeteksi                                  (WARN saja, informational)
      5. (-Full) golden-project run nyata, verifikasi >=1 PNG    (CRITICAL, hanya jika -Full DAN Godot ada)

    Exit 0 = semua CRITICAL lulus. Exit 1 = ada CRITICAL gagal.

    Cek yang dilewati karena dependency tidak ada (mis. Godot belum terpasang) TIDAK dihitung
    gagal -- tapi ringkasan akhir melaporkannya secara eksplisit sebagai "LULUS SEBAGIAN" dan
    menyebut apa yang belum diverifikasi. Tanpa Godot, satu-satunya cek yang benar-benar berjalan
    adalah AST-parse; melaporkan "OK" polos di kondisi itu menyesatkan.

.PARAMETER KiloRoot
    Root direktori yang berisi tools/, godot-templates/, game-state-templates/.
    Struktur ~/.config/kilo dan root repo identik 1:1, jadi script yang sama
    bisa dipakai untuk cek pra-sync (-KiloRoot ke root repo) maupun pasca-sync
    (default, ~/.config/kilo).
    Default: ~/.config/kilo.

.PARAMETER GodotExe
    Path ke Godot executable. Jika kosong, dicari otomatis.

.PARAMETER ImageMagickExe
    Path ke ImageMagick executable. Jika kosong, dicari otomatis.

.PARAMETER Full
    Jika di-set, jalankan juga cek #5 (golden-project run nyata via Godot).
    Default: skip -- cek #1-4 saja berjalan dalam hitungan detik.

.EXAMPLE
    & ".\tools\doctor.ps1" -KiloRoot "C:\dev\ai-game-dev-framework"
    & "$env:USERPROFILE\.config\kilo\tools\doctor.ps1"
    & "$env:USERPROFILE\.config\kilo\tools\doctor.ps1" -Full
#>

[CmdletBinding()]
param(
    [string] $KiloRoot       = (Join-Path $env:USERPROFILE ".config\kilo"),
    [string] $GodotExe       = "",
    [string] $ImageMagickExe = "",
    [switch] $Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPs1 = Join-Path $PSScriptRoot "_common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    Write-Host "[doctor] FAIL _common.ps1 tidak ditemukan di $PSScriptRoot" -ForegroundColor Red
    Write-Host "[doctor]      Instalasi tidak lengkap. Jalankan setup.ps1 dari root repo framework." -ForegroundColor Red
    exit 1
}
. $commonPs1

function Write-Ok   { param($msg) Write-Host "[doctor] OK   $msg" -ForegroundColor Green  }
function Write-Warn { param($msg) Write-Host "[doctor] WARN $msg" -ForegroundColor Yellow }
function Write-Bad  { param($msg) Write-Host "[doctor] FAIL $msg" -ForegroundColor Red    }

$criticalFail  = $false
# Cek yang dilewati karena dependency tidak tersedia (bukan kegagalan, tapi HARUS dilaporkan --
# "OK" yang tidak menyebutkan apa yang tidak diverifikasi adalah laporan yang menyesatkan).
$skippedChecks = @()

Write-Host ""
Write-Host "[doctor] ================================================" -ForegroundColor Cyan
Write-Host "[doctor]  Healthcheck -- $KiloRoot" -ForegroundColor Cyan
Write-Host "[doctor] ================================================" -ForegroundColor Cyan

# -- 1. Semua tools/*.ps1 AST parse bersih ---------------------------------------
# Sengaja SEMUA tool, bukan shot-harness saja: sejak tools/ berbagi _common.ps1, satu
# perubahan bisa merusak beberapa file sekaligus. Healthcheck yang cuma memeriksa satu
# script akan meloloskan syntax error di visual-diff/run-and-analyze/autonomous-qa dan
# baru ketahuan saat user memakainya.
$toolsDir    = Join-Path $KiloRoot "tools"
$harnessPath = Join-Path $toolsDir "shot-harness.ps1"
if (-not (Test-Path -LiteralPath $toolsDir)) {
    Write-Bad "Direktori tools/ tidak ditemukan: $toolsDir"
    $criticalFail = $true
} else {
    $psFiles = @(Get-ChildItem -LiteralPath $toolsDir -Filter "*.ps1" -ErrorAction SilentlyContinue)
    if ($psFiles.Count -eq 0) {
        Write-Bad "Tidak ada file .ps1 di $toolsDir"
        $criticalFail = $true
    } else {
        $parseFails = @()
        foreach ($f in $psFiles) {
            try {
                $parseErrors = $null
                [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
                if ($parseErrors.Count -gt 0) {
                    $first = $parseErrors[0]
                    $parseFails += ("$($f.Name) L$($first.Extent.StartLineNumber): $($first.Message)")
                }
            } catch {
                $parseFails += ("$($f.Name): exception $_")
            }
        }
        if ($parseFails.Count -eq 0) {
            Write-Ok "$($psFiles.Count) tool .ps1 parse bersih"
        } else {
            foreach ($pf in $parseFails) { Write-Bad "Parse error: $pf" }
            $criticalFail = $true
        }
        if (-not (Test-Path -LiteralPath $harnessPath)) {
            Write-Bad "shot-harness.ps1 tidak ditemukan di $toolsDir"
            $criticalFail = $true
        }
    }
}

# -- 2. Deteksi Godot --------------------------------------------------------------
if ($GodotExe -eq "") { $GodotExe = Resolve-GodotExecutable }
$godotFound = ($GodotExe -ne "") -and (Test-Path -LiteralPath $GodotExe)
if ($godotFound) {
    Write-Ok "Godot ditemukan: $GodotExe"
    # Template .gd framework ini khusus Godot 4.x (JoyButton/MouseButton enum, typed array,
    # await). Godot 3.x lolos deteksi path tapi gagal dengan parse error GDScript yang
    # membingungkan -- lebih baik sebut versinya di sini daripada user menebak-nebak.
    try {
        $verRaw = (& $GodotExe --version 2>&1 | Select-Object -First 1)
        $verStr = if ($null -ne $verRaw) { ([string]$verRaw).Trim() } else { "" }
        if ($verStr -match '^\s*(\d+)\.') {
            $major = [int]$Matches[1]
            if ($major -eq 4) {
                Write-Ok "Versi Godot: $verStr"
            } else {
                Write-Warn "Versi Godot: $verStr -- framework ini menargetkan Godot 4.x"
                Write-Warn "Template .gd kemungkinan besar GAGAL compile di Godot $major.x"
            }
        } else {
            Write-Warn "Versi Godot tidak bisa dibaca (output: '$verStr') -- lanjut tanpa cek versi"
        }
    } catch {
        Write-Warn "Gagal menjalankan '--version' pada Godot -- lanjut tanpa cek versi"
    }
} else {
    Write-Warn "Godot tidak ditemukan -- cek #3 dan #5 (-Full) akan di-skip"
    Write-Warn "Download: https://godotengine.org/download/windows"
}

# -- 3. Compile semua .gd template (vanilla + strict) ------------------------------
$godotTemplatesDir     = Join-Path $KiloRoot "godot-templates"
$gameStateTemplatesDir = Join-Path $KiloRoot "game-state-templates"

if (-not $godotFound) {
    Write-Warn "Skip cek #3 (compile template) -- Godot tidak tersedia"
    $skippedChecks += "compile template .gd (butuh Godot)"
} elseif (-not (Test-Path -LiteralPath $godotTemplatesDir)) {
    Write-Bad "godot-templates/ tidak ditemukan: $godotTemplatesDir"
    $criticalFail = $true
} else {
    $allGdFiles = @()
    $allGdFiles += @(Get-ChildItem -LiteralPath $godotTemplatesDir -Filter "*.gd" -ErrorAction SilentlyContinue)
    if (Test-Path -LiteralPath $gameStateTemplatesDir) {
        $allGdFiles += @(Get-ChildItem -LiteralPath $gameStateTemplatesDir -Filter "*.gd" -ErrorAction SilentlyContinue)
    }

    if ($allGdFiles.Count -eq 0) {
        Write-Bad "Tidak ada file .gd ditemukan di godot-templates/ atau game-state-templates/"
        $criticalFail = $true
    } else {
        # $PID wajib ikut: timestamp beresolusi DETIK saja membuat dua doctor yang jalan
        # dalam detik yang sama memakai direktori yang SAMA. Blok finally milik yang satu
        # menghapusnya saat Godot milik yang lain masih membacanya, menghasilkan
        # "Cannot create file .godot/editor/filesystem_cache10", class_name gagal ter-resolve,
        # lalu dilaporkan sebagai "Template gagal compile" -- kegagalan PALSU pada template
        # yang sebenarnya sehat. Terukur flaky: FAIL, FAIL, OK pada fixture yang sama.
        $checkDir = Join-Path $env:TEMP "kilo_doctor_$PID`_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        try {
            $null = New-Item -ItemType Directory -Path "$checkDir\scripts" -Force

            foreach ($f in $allGdFiles) {
                $dstPath  = "$checkDir\scripts\$($f.Name)"
                $raw      = [System.IO.File]::ReadAllBytes($f.FullName)
                $startIdx = if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { 3 } else { 0 }
                $text     = [System.Text.Encoding]::UTF8.GetString($raw, $startIdx, $raw.Length - $startIdx)
                $noBom    = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($dstPath, $text, $noBom)
            }

            $scriptNames = @($allGdFiles | ForEach-Object { $_.Name })
            $fileListGD  = ($scriptNames | ForEach-Object { '"scripts/' + $_ + '"' }) -join ', '
            # checker.gd sendiri harus typed: ia dikompilasi di project yang sama dengan
            # untyped_declaration=2 aktif, jadi deklarasi tanpa tipe di sini akan membuat
            # checker-nya sendiri gagal parse dan seluruh cek jadi tak pernah berjalan.
            $gdChecker = @"
extends Node
func _ready() -> void:
    var fail_count: int = 0
    for f: String in [$fileListGD]:
        var s: Variant = ResourceLoader.load(f)
        if s == null or not (s is GDScript) or not (s as GDScript).can_instantiate():
            printerr("COMPILE_FAIL: " + f)
            fail_count += 1
        else:
            print("COMPILE_OK: " + f)
    print("RESULT: " + str(fail_count) + " failures")
    get_tree().quit(fail_count)
"@
            [System.IO.File]::WriteAllText("$checkDir\scripts\checker.gd", $gdChecker, (New-Object System.Text.UTF8Encoding($false)))

            # Warning ketat langsung diaktifkan -- ini healthcheck ringan, bukan regresi
            # vanilla-vs-strict terpisah seperti test-pipeline TEST 17.
            #
            # untyped_declaration=2 ikut diuji sejak ditemukan bahwa template framework
            # TIDAK BISA DIMUAT sama sekali di project yang memakainya. bread-adventure
            # memakai setelan itu, dan akibatnya ScenarioRunner.gd gagal parse -- scenario
            # tidak pernah sekali pun berjalan di sana. Framework hanya menguji dua warning
            # lain, jadi ketidakcocokan ini tak pernah terlihat.
            $projGodot = "config_version=5`n`n[application]`nconfig/name=`"DoctorCheck`"`nrun/main_scene=`"res://main.tscn`"`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`n`n[debug]`ngdscript/warnings/unsafe_method_access=2`ngdscript/warnings/unsafe_property_access=2`ngdscript/warnings/untyped_declaration=2`n"
            [System.IO.File]::WriteAllText("$checkDir\project.godot", $projGodot, (New-Object System.Text.UTF8Encoding($false)))

            $mainTscn = "[gd_scene load_steps=2 format=3]`n[ext_resource type=""Script"" path=""res://scripts/checker.gd"" id=""1""]`n[node name=""Main"" type=""Node""]`nscript = ExtResource(""1"")`n"
            [System.IO.File]::WriteAllText("$checkDir\main.tscn", $mainTscn, (New-Object System.Text.UTF8Encoding($false)))

            $impProc = Start-Process $GodotExe -ArgumentList "--path", "`"$checkDir`"", "--import", "--quit-after", "2" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($impProc) { $impProc.Handle | Out-Null; $impProc.WaitForExit(30000) | Out-Null }

            # Nama unik per-proses: dua doctor.ps1 yang jalan bersamaan (mis. suite regresi
            # yang memanggilnya beberapa kali, atau CI paralel) tidak boleh saling menimpa log.
            $checkLog = Join-Path $env:TEMP "kilo_doctor_check_$PID.txt"
            $checkOut = Join-Path $env:TEMP "kilo_doctor_out_$PID.txt"
            $proc = Start-Process $GodotExe -ArgumentList "--path", "`"$checkDir`"", "--headless" `
                -PassThru -NoNewWindow -RedirectStandardError $checkLog -RedirectStandardOutput $checkOut `
                -ErrorAction SilentlyContinue
            if ($proc) { $proc.Handle | Out-Null; $proc.WaitForExit(30000) | Out-Null }

            $fails = @()
            if (Test-Path -LiteralPath $checkLog) {
                $fails = @(Get-Content $checkLog -ErrorAction SilentlyContinue | Where-Object {
                    $_ -match "COMPILE_FAIL|Parse Error|Compile Error" -and $_ -notmatch "GDScript::reload"
                })
                Remove-Item -LiteralPath $checkLog -ErrorAction SilentlyContinue
            }

            # Bukti POSITIF bahwa checker benar-benar berjalan, bukan sekadar "tidak ada
            # tanda gagal". Kalau Godot gagal start -- versi salah, project rusak, GPU
            # bermasalah -- stderr bisa saja tidak memuat pola kegagalan sama sekali, dan
            # cek ini akan melaporkan "11 template bersih" tanpa pernah memeriksa apa pun.
            # Itu pola "SKIP dihitung PASS" yang framework ini tolak di tempat lain.
            $ranProof   = $false
            $resultLine = ""
            if (Test-Path -LiteralPath $checkOut) {
                $outLines   = @(Get-Content $checkOut -ErrorAction SilentlyContinue)
                $resultLine = ($outLines | Where-Object { $_ -match "^RESULT:\s*(\d+)\s+failures" } | Select-Object -First 1)
                $okCount    = @($outLines | Where-Object { $_ -match "^COMPILE_OK:" }).Count
                # Checker dianggap benar-benar jalan hanya jika ia sempat mencetak RESULT
                # DAN jumlah OK + gagal menutupi seluruh template yang seharusnya diperiksa.
                if ($resultLine -and $resultLine -match "^RESULT:\s*(\d+)") {
                    $reportedFails = [int]$Matches[1]
                    $ranProof = (($okCount + $reportedFails) -ge $allGdFiles.Count)
                }
                Remove-Item -LiteralPath $checkOut -ErrorAction SilentlyContinue
            }

            if (-not $ranProof) {
                Write-Bad "Compile check tidak selesai -- Godot tidak mencetak hasil untuk semua $($allGdFiles.Count) template"
                Write-Bad "      Ini BUKAN 'lulus': tidak ada bukti template pernah diperiksa."
                Write-Bad "      Kemungkinan Godot gagal start. Jalankan manual untuk melihat sebabnya."
                $criticalFail = $true
            } elseif ($fails.Count -eq 0) {
                Write-Ok "$($allGdFiles.Count) template .gd compile bersih (strict unsafe_method_access=2)"
            } else {
                Write-Bad "Template gagal compile: $($fails[0])"
                $criticalFail = $true
            }
        } catch {
            Write-Bad "Compile check exception: $_"
            $criticalFail = $true
        } finally {
            Remove-Item -LiteralPath $checkDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\DoctorCheck" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- 4. Deteksi ImageMagick ---------------------------------------------------------
if ($ImageMagickExe -eq "") { $ImageMagickExe = Resolve-ImageMagick }
if (($ImageMagickExe -ne "") -and (Test-Path -LiteralPath $ImageMagickExe)) {
    Write-Ok "ImageMagick ditemukan: $ImageMagickExe"
} else {
    Write-Warn "ImageMagick tidak ditemukan -- visual-diff akan fallback ke MD5 hash comparison"
    Write-Warn "Install: https://imagemagick.org"
}

# -- 5. (-Full) golden-project run nyata ---------------------------------------------
if ($Full) {
    if (-not $godotFound) {
        Write-Warn "Skip cek #5 (-Full golden project) -- Godot tidak tersedia"
        $skippedChecks += "golden-project run (butuh Godot)"
    } elseif (-not (Test-Path -LiteralPath $harnessPath)) {
        Write-Warn "Skip cek #5 (-Full golden project) -- shot-harness.ps1 tidak ditemukan"
        $skippedChecks += "golden-project run (shot-harness.ps1 tidak ada)"
    } else {
        # $PID -- alasan sama seperti $checkDir di atas
        $goldenDir     = Join-Path $env:TEMP "kilo_doctor_golden_$PID`_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $goldenScripts = Join-Path $goldenDir "scripts"
        try {
            $null = New-Item -ItemType Directory -Path $goldenScripts -Force

            $goldenProjContent = "[configuration]`nconfig_version=5`n`n[application]`nconfig/name=`"DoctorGolden`"`nrun/main_scene=`"res://main.tscn`"`nconfig/features=PackedStringArray(`"4.7`")`n`n[autoload]`nGameStateWriter=`"*res://scripts/GameStateWriter.gd`"`nErrorTracker=`"*res://scripts/ErrorTracker.gd`"`n"
            [System.IO.File]::WriteAllText((Join-Path $goldenDir "project.godot"), $goldenProjContent, (New-Object System.Text.UTF8Encoding($false)))

            $mainTscnContent = "[gd_scene format=3 uid=`"uid://doctor_golden_main`"]`n`n[ext_resource type=`"Script`" path=`"res://scripts/main.gd`" id=`"1_main`"]`n`n[node name=`"Main`" type=`"Node`"]`nscript = ExtResource(`"1_main`")`n"
            [System.IO.File]::WriteAllText((Join-Path $goldenDir "main.tscn"), $mainTscnContent, (New-Object System.Text.UTF8Encoding($false)))

            @"
extends Node

func _ready() -> void:
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
"@ | Set-Content (Join-Path $goldenScripts "main.gd") -Encoding UTF8

            foreach ($tmpl in @("GameStateWriter.gd", "ErrorTracker.gd")) {
                $src = Join-Path $godotTemplatesDir $tmpl
                if (Test-Path -LiteralPath $src) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $goldenScripts $tmpl) -Force
                }
            }

            $goldenShots = "$env:APPDATA\Godot\app_userdata\DoctorGolden\shots"
            if (Test-Path $goldenShots) { Remove-Item -LiteralPath $goldenShots -Recurse -Force -ErrorAction SilentlyContinue }

            $null = Start-Process -FilePath $GodotExe -ArgumentList "--path", "`"$goldenDir`"", "--headless", "--import", "--quit" `
                -PassThru -NoNewWindow -Wait
            $null = & $harnessPath -ProjectPath $goldenDir -GodotExe $GodotExe -Timeout 60 2>&1

            $pngs = @(Get-ChildItem $goldenShots -Filter "*.png" -ErrorAction SilentlyContinue)
            if ($pngs.Count -ge 1) {
                Write-Ok "Golden project run: $($pngs.Count) PNG dihasilkan"
            } else {
                Write-Bad "Golden project run: 0 PNG dihasilkan"
                $criticalFail = $true
            }
        } catch {
            Write-Bad "Golden project run exception: $_"
            $criticalFail = $true
        } finally {
            Remove-Item -LiteralPath $goldenDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:APPDATA\Godot\app_userdata\DoctorGolden" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- Summary --------------------------------------------------------------------------
Write-Host "[doctor] ------------------------------------------------" -ForegroundColor DarkGray
if ($criticalFail) {
    Write-Host "[doctor]  Healthcheck GAGAL -- ada masalah CRITICAL di atas" -ForegroundColor Red
} elseif ($skippedChecks.Count -gt 0) {
    # Jangan laporkan "OK" polos: sebagian besar verifikasi yang berarti tidak dijalankan.
    Write-Host "[doctor]  Healthcheck LULUS SEBAGIAN -- $($skippedChecks.Count) cek dilewati" -ForegroundColor Yellow
    foreach ($s in $skippedChecks) {
        Write-Host "[doctor]    - belum diverifikasi: $s" -ForegroundColor Yellow
    }
    Write-Host "[doctor]  Pasang dependency yang kurang lalu jalankan ulang untuk verifikasi penuh." -ForegroundColor Yellow
} else {
    Write-Host "[doctor]  Healthcheck OK -- semua cek dijalankan" -ForegroundColor Green
}
Write-Host "[doctor] ================================================" -ForegroundColor Cyan
Write-Host ""

exit $(if ($criticalFail) { 1 } else { 0 })
