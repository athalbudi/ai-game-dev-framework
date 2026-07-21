<#
.SYNOPSIS
    Harness screenshot global untuk game Godot.
    Jalankan --shot tour di project Godot manapun, lalu post-process zoom area kritis.

.DESCRIPTION
    Script ini bersifat game-agnostik - tidak ada kode game di sini.
    Semua logika navigasi layar tetap di dalam kode game (flag --shot).
    Script ini hanya bertanggung jawab untuk:
      1. Validasi environment (Godot executable, project path)
      2. Menjalankan Godot dengan flag --shot dan menunggu selesai
      3. Membaca konfigurasi zoom dari file shots.zoom.json (opsional, per-game)
      4. Post-process: crop area kritis dari PNG hasil harness
      5. Menulis state.json universal (layer 0) — metadata harness tanpa data game-specific
      6. Membaca game_state.json (layer 1) jika ditulis game, merge ke manifest
      7. Menulis shots-manifest.json gabungan untuk AI visual-qa
      8. Print ringkasan: fase telemetry, daftar file, timestamp

    Arsitektur telemetry dua layer:
      Layer 0 (harness) — state.json
        Ditulis oleh harness ini. Selalu ada untuk game apapun.
        Berisi: project_name, timestamp, png_count, daftar screens, telemetry_phase.

      Layer 1 (game hook) — game_state.json
        Ditulis oleh game itu sendiri saat --shot mode.
        Format bebas, tidak ada schema yang dipaksakan.
        Jika tidak ada: telemetry_phase = prototype atau developing.
        Jika ada: telemetry_phase = mature. Isi di-embed ke manifest sebagai game_state.

    Fase telemetry (deteksi otomatis):
      prototype   — belum ada PNG, belum ada game_state.json (game baru dibuat)
      developing  — ada PNG tapi belum ada game_state.json
      mature      — ada PNG dan ada game_state.json (game sudah implementasi hook)

.PARAMETER ProjectPath
    Path absolut ke folder project Godot (yang berisi project.godot).
    Default: direktori kerja saat ini.

.PARAMETER GodotExe
    Path ke executable Godot. Jika tidak diisi, script mencari otomatis di:
      - C:\Godot\Godot_v*_win64_console.exe
      - C:\Program Files\Godot\*.exe
      - $env:PATH

.PARAMETER ShotsDir
    Path folder output PNG. Jika tidak diisi, dibaca dari project.godot
    (user:// = %APPDATA%\Godot\app_userdata\<nama_project>\shots).

.PARAMETER ZoomConfig
    Path ke file JSON konfigurasi zoom. Default: <ProjectPath>\shots.zoom.json
    Format JSON (field "description" opsional):
    [
      { "src": "16_actionbar_worst.png", "x": 0, "y": 1360, "w": 720, "h": 200, "out": "zoom_actionbar.png" },
      { "src": "18_disabled_reason.png", "x": 0, "y": 1200, "w": 720, "h": 260, "out": "zoom_disabled.png" }
    ]

.PARAMETER Timeout
    Batas waktu tunggu Godot dalam detik. Default: 120.

.PARAMETER NoRun
    Jika diset, skip langkah menjalankan Godot dan langsung ke post-process zoom.
    Berguna jika shots sudah fresh dan hanya ingin re-crop saja.
    Catatan: jika -ShotsDir juga di-set eksplisit, validasi project.godot di-skip.

.EXAMPLE
    # Jalankan di project game baru
    .\shot-harness.ps1 -ProjectPath "C:\dev\mygame"

.EXAMPLE
    # Tentukan Godot dan shots dir secara eksplisit
    .\shot-harness.ps1 `
        -ProjectPath "C:\dev\mygame" `
        -GodotExe "C:\Godot\Godot_v4.7-stable_win64_console.exe" `
        -ShotsDir "C:\dev\mygame\screenshots"

.EXAMPLE
    # Jalankan dari folder project tanpa argumen
    cd "C:\dev\mygame"
    & "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1"

.EXAMPLE
    # Skip Godot, hanya re-run zoom crop saja
    .\shot-harness.ps1 -ProjectPath "C:\dev\mygame" -NoRun

.NOTES
    Untuk game baru: ganti -ProjectPath ke path project Godot Anda.
    Buat shots.zoom.json di root project untuk mengaktifkan zoom otomatis.
#>

[CmdletBinding()]
param(
    [string] $ProjectPath = (Get-Location).Path,
    [string] $GodotExe    = "",
    [string] $ShotsDir    = "",
    [string] $ZoomConfig  = "",
    [int]    $Timeout     = 120,
    [switch] $NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Warna output ---------------------------------------------------------------
function Write-Step { param($msg) Write-Host "[shot] $msg"      -ForegroundColor Cyan   }
function Write-Ok   { param($msg) Write-Host "[shot] OK  $msg"  -ForegroundColor Green  }
function Write-Warn { param($msg) Write-Host "[shot] WARN $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "[shot] FAIL $msg" -ForegroundColor Red; exit 1 }

# -- 1. Validasi project path ---------------------------------------------------
# Jika -NoRun dan -ShotsDir keduanya di-set, skip validasi project.godot
$skipProjectCheck = $NoRun -and ($ShotsDir -ne "")

if (-not $skipProjectCheck) {
    Write-Step "Memeriksa project: $ProjectPath"
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        Write-Fail "ProjectPath tidak ditemukan: $ProjectPath"
    }
    $projectGodot = Join-Path $ProjectPath "project.godot"
    if (-not (Test-Path -LiteralPath $projectGodot)) {
        Write-Fail "Bukan project Godot valid - project.godot tidak ada di: $ProjectPath"
    }
    Write-Ok "project.godot ditemukan"
} else {
    Write-Step "Skip validasi project.godot (-NoRun + -ShotsDir eksplisit)"
}

# -- 2. Resolve shots directory -------------------------------------------------
if ($ShotsDir -eq "") {
    $projectGodot = Join-Path $ProjectPath "project.godot"
    $projectName  = ""
    $rawContent   = Get-Content -LiteralPath $projectGodot -Raw
    if ($rawContent -match 'config/name="([^"]+)"') {
        $projectName = $Matches[1]
    }
    if ($projectName -eq "") {
        $projectName = (Get-Item $ProjectPath).Name
        Write-Warn "Nama project tidak ditemukan di project.godot, pakai nama folder: $projectName"
    }
    # Sanitasi karakter yang tidak valid di path Windows
    $safeName = $projectName -replace '[\\/:*?"<>|]', '_'
    if ($safeName -ne $projectName) {
        Write-Warn "Nama project disanitasi: '$projectName' -> '$safeName'"
    }
    $ShotsDir = "$env:APPDATA\Godot\app_userdata\$safeName\shots"
}
Write-Step "Output shots: $ShotsDir"

# -- 3. Auto-detect Godot executable --------------------------------------------
if (-not $NoRun) {
    if ($GodotExe -eq "") {
        Write-Step "Mencari Godot executable..."
        $candidates = @(
            "C:\Godot\Godot_v4.7-stable_win64_console.exe",
            "C:\Godot\Godot_v4.7-stable_win64.exe",
            "C:\Program Files\Godot\Godot_v4.7-stable_win64_console.exe",
            "C:\Program Files\Godot\Godot.exe"
        )
        # Cari versi apapun di C:\Godot\ - ambil terbaru
        if (Test-Path "C:\Godot") {
            $found = Get-ChildItem "C:\Godot" -Filter "*win64_console.exe" -ErrorAction SilentlyContinue |
                     Sort-Object Name -Descending | Select-Object -First 1
            if ($found) { $candidates = @($found.FullName) + $candidates }
        }
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) { $GodotExe = $c; break }
        }
        # Fallback: cari di PATH
        if ($GodotExe -eq "") {
            $fromPath = Get-Command "godot" -ErrorAction SilentlyContinue
            if ($fromPath) { $GodotExe = $fromPath.Source }
        }
        if ($GodotExe -eq "") {
            Write-Fail "Godot executable tidak ditemukan. Tentukan path via -GodotExe."
        }
    }
    if (-not (Test-Path -LiteralPath $GodotExe)) {
        Write-Fail "GodotExe tidak ada: $GodotExe"
    }
    Write-Ok "Godot: $GodotExe"
}

# -- 4. Jalankan Godot --shot ---------------------------------------------------
if ($NoRun) {
    Write-Step "-NoRun diset - skip menjalankan Godot, langsung ke post-process zoom"
    $ts_start = Get-Date
    $ts_end   = $ts_start
    $elapsed  = 0
} else {
    Write-Step "Menjalankan harness --shot..."
    $ts_start = Get-Date

    # -- Deteksi hang vs slow ---------------------------------------------------
    # Masalah: WaitForExit($ms) hanya tahu "selesai atau timeout" — tidak bisa
    # membedakan game yang berjalan lambat vs game yang hang / infinite loop.
    #
    # Strategi deteksi tiga lapisan:
    #   1. Progress heartbeat — pantau jumlah PNG di ShotsDir setiap interval.
    #      Jika PNG bertambah, game sedang berjalan (bukan hang).
    #   2. CPU activity check — jika CPU usage proses 0% untuk waktu panjang,
    #      kemungkinan hang (bukan hanya lambat).
    #   3. Timeout kategorisasi — bedakan timeout biasa vs suspected hang
    #      untuk pesan error yang lebih informatif.
    #
    # Output: $exitCondition = "ok" | "timeout_slow" | "timeout_hang" | "error"
    # Nilai ini dipakai di ringkasan akhir untuk laporan yang tepat ke developer.

    $exitCondition    = "ok"
    $hangCheckSec     = [math]::Max(10, [int]($Timeout * 0.25))  # cek aktivitas setiap 25% timeout
    $pngCountBefore   = 0
    $lastProgressTime = $ts_start
    $noProgressSec    = 0

    # Siapkan ShotsDir untuk heartbeat (mungkin belum ada di awal)
    $heartbeatDir = $ShotsDir
    if (-not (Test-Path -LiteralPath $heartbeatDir -PathType Container)) {
        $heartbeatDir = ""  # folder belum ada, skip heartbeat sampai muncul
    }

    try {
        $proc = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$ProjectPath`"", "--", "--shot" `
            -PassThru -NoNewWindow

        # Pantau proses secara aktif dengan interval $hangCheckSec
        $checkIntervalMs = $hangCheckSec * 1000
        $elapsedMs       = 0
        $timeoutMs       = $Timeout * 1000
        $finished        = $false

        while ($elapsedMs -lt $timeoutMs) {
            $waitMs   = [math]::Min($checkIntervalMs, $timeoutMs - $elapsedMs)
            $finished = $proc.WaitForExit($waitMs)
            if ($finished) { break }

            $elapsedMs += $waitMs
            $now        = Get-Date

            # Heartbeat: cek apakah ada PNG baru di ShotsDir
            if ($heartbeatDir -eq "" -and (Test-Path -LiteralPath $ShotsDir -PathType Container)) {
                $heartbeatDir = $ShotsDir
            }
            $pngCountNow = 0
            if ($heartbeatDir -ne "") {
                try { $pngCountNow = @(Get-ChildItem -LiteralPath $heartbeatDir -Filter "*.png" -ErrorAction SilentlyContinue).Count } catch { }
            }

            if ($pngCountNow -gt $pngCountBefore) {
                # Ada progress — update marker
                $pngCountBefore   = $pngCountNow
                $lastProgressTime = $now
                $noProgressSec    = 0
                Write-Step "Heartbeat: $pngCountNow PNG dihasilkan (${elapsedMs}ms berlalu)..."
            } else {
                $noProgressSec = ($now - $lastProgressTime).TotalSeconds
            }

            # CPU activity check — hanya jika System.Diagnostics tersedia
            $cpuWarned = $false
            if (-not $cpuWarned -and $noProgressSec -gt ($hangCheckSec * 2)) {
                try {
                    $proc.Refresh()
                    # Ambil dua sample CPU time dengan jeda 1 detik
                    $cpu1 = $proc.TotalProcessorTime
                    Start-Sleep -Milliseconds 1000
                    $proc.Refresh()
                    $cpu2 = $proc.TotalProcessorTime
                    $cpuDeltaMs = ($cpu2 - $cpu1).TotalMilliseconds

                    if ($cpuDeltaMs -lt 5) {
                        # CPU nyaris 0% selama 1 detik — kemungkinan hang
                        Write-Warn "Suspected hang: tidak ada progress PNG + CPU ~0% selama $([int]$noProgressSec)s"
                        Write-Warn "Game mungkin menunggu input, terjebak di infinite loop, atau crash diam-diam."
                        $cpuWarned = $true
                    } else {
                        Write-Step "Game lambat tapi aktif: CPU delta ${cpuDeltaMs}ms/s, no progress ${noProgressSec}s"
                    }
                } catch {
                    # Proses mungkin sudah exit saat dicek — tidak masalah
                }
            }
        }

        if (-not $finished) {
            # Timeout — kategorikan berdasarkan progress terakhir
            $secSinceProgress = ([math]::Round(($ts_start - $lastProgressTime + (Get-Date - $ts_start)).TotalSeconds, 1))
            if ($pngCountBefore -eq 0 -and $noProgressSec -gt ($Timeout * 0.8)) {
                # Tidak ada satu pun PNG yang dihasilkan dan CPU idle lama — likely hang
                $exitCondition = "timeout_hang"
                $proc.Kill()
                Write-Host ""
                Write-Host "[shot] FAIL Timeout ($Timeout detik) — kemungkinan HANG terdeteksi:" -ForegroundColor Red
                Write-Host "       - Tidak ada PNG dihasilkan selama run" -ForegroundColor Red
                Write-Host "       - Tidak ada progress selama $([int]$noProgressSec) detik" -ForegroundColor Red
                Write-Host ""
                Write-Host "[shot] Kemungkinan penyebab:" -ForegroundColor Yellow
                Write-Host "       1. --shot handler belum diimplementasikan di kode game" -ForegroundColor Yellow
                Write-Host "       2. Game menunggu input sebelum memulai shot tour" -ForegroundColor Yellow
                Write-Host "       3. Infinite loop atau deadlock di inisialisasi" -ForegroundColor Yellow
                Write-Host "       4. Error kritis saat startup (cek output Godot di atas)" -ForegroundColor Yellow
                Write-Host ""
                Write-Fail "Timeout: hang suspected. Lihat panduan di atas untuk diagnosa."
            } else {
                # Ada sebagian PNG tapi belum selesai — game lambat atau shot tour tidak terminate
                $exitCondition = "timeout_slow"
                $proc.Kill()
                Write-Host ""
                Write-Host "[shot] FAIL Timeout ($Timeout detik) — game LAMBAT atau shot tour tidak terminate:" -ForegroundColor Red
                Write-Host "       - $pngCountBefore PNG berhasil dihasilkan sebelum timeout" -ForegroundColor Yellow
                Write-Host "       - Tidak ada progress baru selama $([int]$noProgressSec) detik terakhir" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "[shot] Kemungkinan penyebab:" -ForegroundColor Yellow
                Write-Host "       1. Shot tour tidak memanggil get_tree().quit() di akhir" -ForegroundColor Yellow
                Write-Host "       2. Salah satu layar butuh waktu sangat lama (loading, animasi)" -ForegroundColor Yellow
                Write-Host "       3. Tambahkan -Timeout <detik> jika game memang lambat" -ForegroundColor Yellow
                Write-Host ""
                Write-Fail "Timeout: shot tour tidak selesai. $pngCountBefore/$($pngCountBefore + 1) PNG tersimpan."
            }
        }

        if ($proc.ExitCode -ne 0) {
            Write-Warn "Godot exit code $($proc.ExitCode) - harness mungkin tidak sempurna."
        }
    } catch {
        $exitCondition = "error"
        Write-Fail ("Gagal menjalankan Godot: " + $_.ToString())
    }

    $ts_end  = Get-Date
    $elapsed = [math]::Round(($ts_end - $ts_start).TotalSeconds, 1)

    # Kategorikan kecepatan untuk laporan
    $speedCategory = if     ($elapsed -lt 10)  { "cepat" }
                     elseif ($elapsed -lt 30)  { "normal" }
                     elseif ($elapsed -lt 60)  { "lambat" }
                     else                       { "sangat lambat — pertimbangkan optimasi shot tour" }

    Write-Ok "Godot selesai dalam $elapsed detik ($speedCategory)"
}

# -- 5. Validasi output shots ---------------------------------------------------
if (-not (Test-Path -LiteralPath $ShotsDir)) {
    Write-Fail "Folder shots tidak ditemukan: $ShotsDir`nPastikan kode game menyimpan PNG ke user://shots/"
}
$pngFiles = Get-ChildItem -LiteralPath $ShotsDir -Filter "*.png" | Sort-Object Name
if ($pngFiles.Count -eq 0) {
    Write-Fail "Tidak ada PNG di $ShotsDir - harness berjalan tapi tidak menghasilkan screenshot."
}
Write-Ok "$($pngFiles.Count) PNG ditemukan di $ShotsDir"

# -- 6. Deteksi PNG hitam (headless guard) -------------------------------------
# Dijalankan selalu - termasuk saat -NoRun - agar shots lama yang hitam terdeteksi
Add-Type -AssemblyName System.Drawing
$blackCount = 0
foreach ($f in $pngFiles | Select-Object -First 3) {
    try {
        $bmp   = [System.Drawing.Bitmap]::FromFile($f.FullName)
        $pixel = $bmp.GetPixel([int]($bmp.Width / 2), [int]($bmp.Height / 2))
        $bmp.Dispose()
        if ($pixel.R -lt 5 -and $pixel.G -lt 5 -and $pixel.B -lt 5) { $blackCount++ }
    } catch { }
}
if ($blackCount -ge 2) {
    Write-Warn "Sebagian besar PNG terdeteksi hitam - kemungkinan Godot dijalankan dengan --headless."
    Write-Warn "Pastikan kode game TIDAK menambahkan --headless saat menjalankan harness."
}

# -- 7. Post-process: zoom crop -------------------------------------------------
if ($ZoomConfig -eq "") {
    $ZoomConfig = Join-Path $ProjectPath "shots.zoom.json"
}

if (Test-Path -LiteralPath $ZoomConfig) {
    Write-Step "Membaca konfigurasi zoom: $ZoomConfig"
    $zoomDefs  = Get-Content -LiteralPath $ZoomConfig -Raw | ConvertFrom-Json
    $zoomCount = 0
    foreach ($z in $zoomDefs) {
        # Validasi field wajib - cegah crash dengan pesan jelas
        $requiredFields = @("src", "x", "y", "w", "h", "out")
        $missingFields  = @($requiredFields | Where-Object { -not ($z.PSObject.Properties.Name -contains $_) })
        if ($missingFields.Count -gt 0) {
            Write-Warn "Zoom entry dilewati - field wajib tidak ada: $($missingFields -join ', ')"
            continue
        }
        $srcPath = Join-Path $ShotsDir $z.src
        if (-not (Test-Path -LiteralPath $srcPath)) {
            Write-Warn "Zoom skip (src tidak ada): $($z.src)"
            continue
        }
        # Gunakan try/finally agar $src selalu di-dispose meski Clone atau Save throw
        $src = $null
        $crop = $null
        try {
            $src = [System.Drawing.Bitmap]::FromFile($srcPath)
            $iw  = $src.Width
            $ih  = $src.Height
            # Validasi resolusi - peringatkan kalau expected_width/expected_height di-set tapi tidak cocok
            if ($z.PSObject.Properties.Name -contains "expected_width" -and $iw -ne [int]$z.expected_width) {
                Write-Warn "Zoom resolusi tidak cocok untuk $($z.src): expected width=$([int]$z.expected_width) actual=$iw - koordinat zoom mungkin salah"
            }
            if ($z.PSObject.Properties.Name -contains "expected_height" -and $ih -ne [int]$z.expected_height) {
                Write-Warn "Zoom resolusi tidak cocok untuk $($z.src): expected height=$([int]$z.expected_height) actual=$ih - koordinat zoom mungkin salah"
            }
            # Clamp koordinat agar tidak melebihi ukuran gambar
            $x = [math]::Max(0, [math]::Min([int]$z.x, $iw - 1))
            $y = [math]::Max(0, [math]::Min([int]$z.y, $ih - 1))
            $w = [math]::Max(1, [math]::Min([int]$z.w, $iw - $x))
            $h = [math]::Max(1, [math]::Min([int]$z.h, $ih - $y))
            $rect    = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
            $crop    = $src.Clone($rect, $src.PixelFormat)
            $outPath = Join-Path $ShotsDir $z.out
            $crop.Save($outPath)
            Write-Ok "Zoom: $($z.src) [$x,$y,$w,$h] -> $($z.out)"
            $zoomCount++
        } catch {
            Write-Warn "Zoom gagal untuk $($z.src): $_"
        } finally {
            if ($crop -ne $null) { $crop.Dispose() }
            if ($src  -ne $null) { $src.Dispose()  }
        }
    }
    Write-Ok "$zoomCount zoom crop dihasilkan"
} else {
    Write-Step "shots.zoom.json tidak ditemukan - skip zoom crop"
    Write-Step "  Buat $ZoomConfig untuk mengaktifkan zoom otomatis."
    Write-Step '  Contoh: [{"src":"screen.png","x":0,"y":100,"w":720,"h":200,"out":"zoom.png"}]'
}

# -- 8. Ringkasan akhir ---------------------------------------------------------
$allPng   = Get-ChildItem -LiteralPath $ShotsDir -Filter "*.png" | Sort-Object Name

# Deteksi shot stale - file yang jauh lebih lama dari sisanya
if ($allPng.Count -gt 1) {
    $timestamps = $allPng | ForEach-Object { $_.LastWriteTime }
    $newest = ($timestamps | Sort-Object -Descending)[0]
    foreach ($f in $allPng) {
        $ageDiff = ($newest - $f.LastWriteTime).TotalHours
        if ($ageDiff -gt 1) {
            Write-Warn "Shot stale: $($f.Name) ($([math]::Round($ageDiff,1)) jam lebih lama dari run terbaru)"
        }
    }
}

# -- 8a. Tulis state.json universal (layer 0 — ditulis harness, bukan game) -----
# state.json berisi metadata yang SELALU tersedia untuk game apapun:
# engine info, project info, timestamp, daftar PNG, dan telemetry phase.
# Ini adalah fondasi universal workflow AI-assisted game development.
#
# Konvensi tiga fase:
#   prototype   — game baru, belum ada data gameplay (hanya metadata harness)
#   developing  — game punya minimal satu layar + bisa jalan hingga selesai
#   mature      — game punya game_state.json (ditulis game sendiri)
#
# Deteksi fase: harness cek keberadaan game_state.json untuk upgrade ke "mature".

$gameState     = $null
$gameStateJson = Join-Path $ShotsDir "game_state.json"
$telemetryPhase = "prototype"

if (Test-Path -LiteralPath $gameStateJson) {
    try {
        $gameState = Get-Content -LiteralPath $gameStateJson -Raw | ConvertFrom-Json
        $telemetryPhase = "mature"
        Write-Ok "Game state terbaca dari game_state.json (fase: mature)"
    } catch {
        Write-Warn "game_state.json ditemukan tapi gagal di-parse: $_"
    }
} elseif ($allPng.Count -gt 0) {
    $telemetryPhase = "developing"
    Write-Step "game_state.json tidak ditemukan - telemetry fase: developing"
    Write-Step "  Untuk naik ke fase mature: game tulis data ke user://shots/game_state.json"
} else {
    Write-Step "Tidak ada PNG dan game_state.json - telemetry fase: prototype"
}

# Baca project name dari project.godot jika tersedia
$projectNameForState = ""
if (-not $skipProjectCheck) {
    $rawForState = Get-Content -LiteralPath (Join-Path $ProjectPath "project.godot") -Raw -ErrorAction SilentlyContinue
    if ($rawForState -and $rawForState -match 'config/name="([^"]+)"') {
        $projectNameForState = $Matches[1]
    }
}
if ($projectNameForState -eq "") {
    $projectNameForState = (Get-Item $ProjectPath -ErrorAction SilentlyContinue).Name
}

# Tulis state.json — layer 0, universal, tidak ada data game-specific di sini
$stateLayer0 = [ordered]@{
    # Metadata harness (selalu ada)
    harness_version  = "2.0"
    generated_at     = $ts_end.ToString("yyyy-MM-dd HH:mm:ss")
    telemetry_phase  = $telemetryPhase  # prototype | developing | mature
    # Metadata project (dari project.godot, universal untuk semua Godot game)
    project_name     = $projectNameForState
    project_path     = $ProjectPath
    # Data run harness
    elapsed_sec      = $elapsed
    png_count        = $allPng.Count
    shots_dir        = $ShotsDir
    # Daftar layar yang dihasilkan — context untuk AI tanpa harus baca semua PNG
    screens          = @($allPng | Where-Object { $_.Name -notlike "zoom_*" } | ForEach-Object {
        [ordered]@{
            file     = $_.Name
            size_kb  = [math]::Round($_.Length / 1024, 1)
        }
    })
    # Pointer ke game_state.json jika ada (null = game belum implementasi hook)
    game_state       = $gameState
}
$stateJsonPath = Join-Path $ShotsDir "state.json"
try {
    $stateLayer0 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateJsonPath -Encoding UTF8
    Write-Ok "state.json ditulis (fase: $telemetryPhase)"
} catch {
    Write-Warn "Gagal menulis state.json: $_"
}

# -- 8b. Tulis shots-manifest.json ---------------------------------------------
# Manifest ini dibaca oleh agent visual-qa dan command /analisis-shot
# sebagai konteks gabungan: daftar PNG + state universal + metadata run.
$manifestPath = Join-Path $ShotsDir "shots-manifest.json"
# Cek baseline staleness — baca baseline-manifest.json jika ada
$baselineDir      = Join-Path $ShotsDir "baseline"
$baselineManifest = Join-Path $baselineDir "baseline-manifest.json"
$baselineAge      = $null
$baselineDate     = $null
if (Test-Path -LiteralPath $baselineManifest) {
    try {
        $bm = Get-Content -LiteralPath $baselineManifest -Raw | ConvertFrom-Json
        if ($bm.generated_at) {
            # Support kedua format: "yyyy-MM-dd HH:mm:ss" (manifest lama) dan ISO 8601 "yyyy-MM-ddTHH:mm:ss"
            $formats = @("yyyy-MM-dd HH:mm:ss", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-ddTHH:mm:ssZ")
            $parsed  = $null
            foreach ($fmt in $formats) {
                try { $parsed = [datetime]::ParseExact($bm.generated_at, $fmt, $null); break } catch { }
            }
            if ($parsed) {
                $baselineDate = $parsed
                $baselineAge  = [math]::Round(($ts_end - $baselineDate).TotalDays, 1)
            }
        }
    } catch { }
}

$manifestData = [ordered]@{
    schema_version    = "1.1"   # bump saat format manifest berubah — lihat FRAMEWORK.md
    generated_at      = $ts_end.ToString("yyyy-MM-dd HH:mm:ss")
    elapsed_sec       = $elapsed
    shots_dir         = $ShotsDir
    project_path      = $ProjectPath
    project_name      = $projectNameForState
    png_count         = $allPng.Count
    telemetry_phase   = $telemetryPhase   # prototype | developing | mature
    baseline_age_days = $baselineAge      # null jika belum ada baseline
    screenshots       = @($allPng | Where-Object { $_.Name -notlike "*.json" } | ForEach-Object {
        [ordered]@{
            file         = $_.Name
            size_kb      = [math]::Round($_.Length / 1024, 1)
            last_write   = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
    })
    # game_state: null  = prototype/developing (game belum tulis game_state.json)
    #             {...} = mature (game sudah implementasi telemetry hook)
    game_state        = $gameState
}
try {
    $manifestData | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Ok "Manifest ditulis: shots-manifest.json"
} catch {
    Write-Warn "Gagal menulis shots-manifest.json: $_"
}

# -- 8c. Shot tour coverage tracker -------------------------------------------
# Bandingkan screen yang diketahui game (dari game_state.json) vs PNG yang ada.
# Tujuan: deteksi silent coverage gap — screen baru yang belum masuk shot tour.
#
# Sumber screen yang diketahui (prioritas):
#   1. game_state.current_screen (screen aktif saat harness dijalankan)
#   2. Nama PNG yang ada di ShotsDir (strip prefix angka dan suffix .png)
#
# Coverage dihitung: berapa screen dari game_state terwakili di PNG?
# Warning jika ada screen di game_state yang tidak punya PNG.

$coverageResult = [ordered]@{
    enabled        = $false
    known_screens  = @()
    covered        = @()
    uncovered      = @()
    coverage_pct   = $null
    note           = ""
}

# Ekstrak nama screen dari nama PNG (format: NN_screenname.png atau screenname.png)
$pngScreenNames = @($allPng | Where-Object { $_.Name -notlike "zoom_*" -and $_.Name -notlike "diff_*" } | ForEach-Object {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    # Strip prefix angka: "03_battle" -> "battle", "03" -> "03" (tetap)
    if ($name -match '^\d+_(.+)$') { $Matches[1] } else { $name }
})

# Kumpulkan screen yang diketahui dari game_state
$knownScreens = [System.Collections.Generic.List[string]]::new()

if ($gameState -ne $null) {
    $coverageResult.enabled = $true

    # Sumber 1: current_screen di root
    if ($gameState.PSObject.Properties.Name -contains "current_screen" -and
        $gameState.current_screen -ne $null -and
        $gameState.current_screen -ne "") {
        $knownScreens.Add($gameState.current_screen.ToLower())
    }

    # Sumber 2: world.current_scene
    if ($gameState.PSObject.Properties.Name -contains "world" -and
        $gameState.world -ne $null -and
        $gameState.world.PSObject.Properties.Name -contains "current_scene" -and
        $gameState.world.current_scene -ne $null -and
        $gameState.world.current_scene -ne "") {
        $sceneName = $gameState.world.current_scene.ToLower()
        if ($knownScreens -notcontains $sceneName) {
            $knownScreens.Add($sceneName)
        }
    }

    # Sumber 3: semua nama PNG yang ada ditambahkan ke knownScreens sebagai "already covered"
    # PENTING: ini hanya untuk melengkapi known_screens di output manifest (informasi).
    # Evaluasi uncovered hanya dilakukan terhadap screen dari Sumber 1 & 2 (yang game ketahui
    # tapi mungkin belum ada PNG-nya). Screen dari Sumber 3 selalu covered by definition.
    $screenFromGame = @($knownScreens)  # snapshot Sumber 1+2 sebelum ditambah Sumber 3

    foreach ($ps in $pngScreenNames) {
        $psLower = $ps.ToLower()
        if ($knownScreens -notcontains $psLower) {
            $knownScreens.Add($psLower)
        }
    }

    # Hitung coverage:
    # - Jika Sumber 1+2 ada data (game_state expose current_screen/world.current_scene):
    #   evaluasi mana yang punya PNG
    # - Jika Sumber 1+2 kosong (game_state tidak expose field screen tracking):
    #   fallback ke Sumber 3 — semua PNG dianggap covered, coverage = 100%
    #   Ini kasus normal untuk game yang hanya expose data gameplay tanpa screen tracking.
    $covered   = [System.Collections.Generic.List[string]]::new()
    $uncovered = [System.Collections.Generic.List[string]]::new()

    if ($screenFromGame.Count -gt 0) {
        # Ada data dari game — evaluasi coverage Sumber 1+2 vs PNG
        foreach ($screen in $screenFromGame) {
            $hasPng = $pngScreenNames | Where-Object { $_.ToLower() -eq $screen }
            if ($hasPng) { $covered.Add($screen) }
            else         { $uncovered.Add($screen) }
        }
    } else {
        # Tidak ada Sumber 1+2 — fallback: semua PNG dianggap covered
        # game_state ada tapi tidak expose current_screen atau world.current_scene
        foreach ($ps in $pngScreenNames) {
            $covered.Add($ps.ToLower())
        }
    }

    $coverageResult.known_screens = @($knownScreens)
    $coverageResult.covered       = @($covered)
    $coverageResult.uncovered     = @($uncovered)

    if ($knownScreens.Count -gt 0) {
        $pct = [math]::Round(($covered.Count / $knownScreens.Count) * 100, 1)
        $coverageResult.coverage_pct = $pct

        if ($uncovered.Count -gt 0) {
            $coverageResult.note = "WARN: $($uncovered.Count) screen tanpa PNG di shot tour"
            Write-Host ""
            Write-Host "[shot] Coverage tracker:" -ForegroundColor Yellow
            Write-Host "  Diketahui : $($knownScreens.Count) screen" -ForegroundColor Gray
            Write-Host "  Tercakup  : $($covered.Count) screen ($pct%)" -ForegroundColor $(if ($pct -ge 80) { "Green" } else { "Yellow" })
            foreach ($u in $uncovered) {
                Write-Warn "Screen tanpa PNG di shot tour: '$u' — tambahkan ke _shot_tour()"
            }
        } else {
            $coverageResult.note = "OK: semua screen terwakili di shot tour"
            Write-Host ""
            Write-Host "[shot] Coverage tracker: $($covered.Count)/$($knownScreens.Count) screen ($pct%) tercakup" -ForegroundColor Green
        }
    } else {
        $coverageResult.note = "Tidak ada data screen untuk dievaluasi"
    }
} else {
    $coverageResult.note = "game_state.json tidak ada — coverage tracker tidak aktif (fase prototype/developing)"
    Write-Step "Coverage tracker: tidak aktif (butuh game_state.json)"
}

# Tambahkan coverage ke manifest yang sudah ditulis
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $mUpdate = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $mUpdate | Add-Member -NotePropertyName "coverage" -NotePropertyValue $coverageResult -Force
        $mUpdate | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    } catch {
        Write-Warn "Gagal update manifest dengan coverage data: $_"
    }
}

# -- 8d. Validasi assertions dari game_state.json --------------------------------
# Jika game_state.json berisi field "assertions", harness memvalidasinya secara
# deterministik dan menambahkan hasil ke manifest sebagai "assertion_results".
# Ini memberi AI laporan pass/fail yang terukur, bukan hanya "AI menganalisis".

$assertionResults = $null

if ($gameState -ne $null -and
    $gameState.PSObject.Properties.Name -contains "assertions" -and
    $gameState.assertions -ne $null) {

    $assertions   = $gameState.assertions
    $totalAssert  = 0
    $passedAssert = 0
    $failedAssert = 0
    $failureDetails = [System.Collections.Generic.List[object]]::new()

    foreach ($a in $assertions) {
        $totalAssert++

        # Baca nilai actual, op, expected dari assertion
        $actual   = if ($a.PSObject.Properties.Name -contains "actual")   { $a.actual }   else { $null }
        $op       = if ($a.PSObject.Properties.Name -contains "op")       { $a.op }       else { "eq" }
        $expected = if ($a.PSObject.Properties.Name -contains "expected") { $a.expected } else { $null }
        $gameSaysPass = if ($a.PSObject.Properties.Name -contains "pass") { $a.pass }     else { $null }

        # Verifikasi ulang di harness (validasi ganda)
        $harnessPass = switch ($op) {
            "eq"       { $actual -eq $expected }
            "neq"      { $actual -ne $expected }
            "gt"       { $actual -ne $null -and [double]"$actual" -gt  [double]"$expected" }
            "gte"      { $actual -ne $null -and [double]"$actual" -ge  [double]"$expected" }
            "lt"       { $actual -ne $null -and [double]"$actual" -lt  [double]"$expected" }
            "lte"      { $actual -ne $null -and [double]"$actual" -le  [double]"$expected" }
            "not_null" { $actual -ne $null }
            "is_null"  { $actual -eq $null }
            "is_true"  { $actual -eq $true }
            "is_false" { $actual -eq $false }
            "contains" {
                if ($actual -is [string]) { $actual.Contains("$expected") }
                elseif ($actual -is [array]) { $expected -in $actual }
                else { $false }
            }
            default    { $gameSaysPass }  # fallback ke nilai game jika op tidak dikenal
        }

        # Final: preferensi harness, fallback ke game
        $finalPass = if ($harnessPass -ne $null) { $harnessPass } else { $gameSaysPass }

        if ($finalPass -eq $true) {
            $passedAssert++
        } else {
            $failedAssert++
            $failureDetails.Add([ordered]@{
                id          = if ($a.PSObject.Properties.Name -contains "id")          { $a.id }          else { "assertion_$failedAssert" }
                description = if ($a.PSObject.Properties.Name -contains "description") { $a.description } else { "" }
                key         = if ($a.PSObject.Properties.Name -contains "key")         { $a.key }         else { "" }
                op          = $op
                expected    = $expected
                actual      = $actual
            })
        }
    }

    $assertionResults = [ordered]@{
        total    = $totalAssert
        passed   = $passedAssert
        failed   = $failedAssert
        failures = @($failureDetails)
    }

    # Output ringkasan di terminal
    Write-Host ""
    if ($failedAssert -eq 0) {
        Write-Host "[shot] Assertions: $passedAssert/$totalAssert pass" -ForegroundColor Green
    } else {
        Write-Host "[shot] Assertions: $passedAssert/$totalAssert pass — $failedAssert FAIL" -ForegroundColor Red
        foreach ($fd in $failureDetails) {
            Write-Host "  FAIL  [$($fd.id)] $($fd.description)" -ForegroundColor Red
            Write-Host "        key=$($fd.key) op=$($fd.op) expected=$($fd.expected) actual=$($fd.actual)" -ForegroundColor Yellow
        }
    }

    # Update manifest dengan assertion_results
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $mUpdate2 = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $mUpdate2 | Add-Member -NotePropertyName "assertion_results" -NotePropertyValue $assertionResults -Force
            $mUpdate2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        } catch {
            Write-Warn "Gagal update manifest dengan assertion_results: $_"
        }
    }
} else {
    Write-Step "Assertions: tidak ada di game_state.json — skip validasi assertion"
}

# -- 8e. Baca scenario_result.json jika ada ------------------------------------
# Jika game baru saja dijalankan dengan --scenario, hasilnya tersimpan di ShotsDir.
# Harness embed hasilnya ke manifest agar AI punya konteks hasil test scenario.
#
# Fase relevance:
#   prototype   — scenario belum bisa dijalankan (belum ada gameplay flow)
#   developing  — scenario bisa mulai dibuat setelah ada scene + input mapping
#   mature      — scenario bisa berjalan penuh dengan assertions

if ($telemetryPhase -eq "prototype") {
    Write-Step "Scenario testing: belum aktif (fase prototype — belum ada gameplay flow)"
    Write-Step "  Saat game punya scene + input mapping, buat scenarios/ dan jalankan /scenario run"
} elseif ($telemetryPhase -eq "developing") {
    Write-Step "Scenario testing: tersedia (fase developing)"
    Write-Step "  Buat scenarios/scenario_smoke.json dan jalankan /scenario run smoke"
}

$scenarioResultPath = Join-Path $ShotsDir "scenario_result.json"
if (Test-Path -LiteralPath $scenarioResultPath) {
    try {
        $scenarioResult = Get-Content -LiteralPath $scenarioResultPath -Raw | ConvertFrom-Json
        $scStatus = if ($scenarioResult.PSObject.Properties.Name -contains "status")      { $scenarioResult.status }      else { "unknown" }
        $scPassed = if ($scenarioResult.PSObject.Properties.Name -contains "passed")      { $scenarioResult.passed }      else { 0 }
        $scFailed = if ($scenarioResult.PSObject.Properties.Name -contains "failed")      { $scenarioResult.failed }      else { 0 }
        $scTotal  = if ($scenarioResult.PSObject.Properties.Name -contains "total_steps") { $scenarioResult.total_steps } else { 0 }
        $scId     = if ($scenarioResult.PSObject.Properties.Name -contains "scenario_id") { $scenarioResult.scenario_id } else { "unknown" }

        Write-Host ""
        $scColor = if ($scStatus -eq "pass") { "Green" } elseif ($scStatus -eq "fail") { "Red" } else { "Yellow" }
        Write-Host "[shot] Scenario '$scId': $($scStatus.ToUpper()) ($scPassed/$scTotal pass)" -ForegroundColor $scColor

        if ($scFailed -gt 0 -and $scenarioResult.PSObject.Properties.Name -contains "steps") {
            $failedSteps = @($scenarioResult.steps | Where-Object { $_.status -eq "fail" })
            foreach ($fs in $failedSteps) {
                $fsNote = if ($fs.PSObject.Properties.Name -contains "note") { $fs.note } else { "" }
                Write-Host "  FAIL  [$($fs.id)] $fsNote" -ForegroundColor Red
            }
        }

        # Embed ke manifest
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $mUpdate3 = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $mUpdate3 | Add-Member -NotePropertyName "scenario_result" -NotePropertyValue $scenarioResult -Force
                $mUpdate3 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            } catch {
                Write-Warn "Gagal update manifest dengan scenario_result: $_"
            }
        }
    } catch {
        Write-Warn "scenario_result.json ditemukan tapi gagal di-parse: $_"
    }
}

# -- 8f. Coverage history writer + seed enforcement warning --------------------
# Tulis entry coverage terbaru ke coverage-history.json (max 20 entries).
# Juga periksa seed support di game_state dan beri warning jika tidak ada.

# -- 8f-i. Seed enforcement warning
if ($gameState -ne $null -and $telemetryPhase -eq "mature") {
    $hasSeed = $false

    # Cek root-level seed (contoh: game_state.seed = 20260711)
    if ($gameState.PSObject.Properties.Name -contains "seed" -and
        $gameState.seed -ne $null) {
        $hasSeed = $true
    }

    # Cek world.seed (contoh: game_state.world.seed)
    if (-not $hasSeed -and
        $gameState.PSObject.Properties.Name -contains "world" -and
        $gameState.world -ne $null -and
        $gameState.world.PSObject.Properties.Name -contains "seed" -and
        $gameState.world.seed -ne $null) {
        $hasSeed = $true
    }

    # Cek session.seed
    if (-not $hasSeed -and
        $gameState.PSObject.Properties.Name -contains "session" -and
        $gameState.session -ne $null -and
        $gameState.session.PSObject.Properties.Name -contains "seed" -and
        $gameState.session.seed -ne $null) {
        $hasSeed = $true
    }

    if (-not $hasSeed) {
        Write-Host ""
        Write-Warn "Seed tidak ditemukan di game_state — tambahkan field seed untuk reproducibility"
        Write-Host "[shot]      Lokasi yang didukung: game_state.seed, game_state.world.seed, game_state.session.seed" -ForegroundColor Yellow
        Write-Host "[shot]      Seed digunakan oleh ScenarioRunner untuk reproduksi deterministik bug" -ForegroundColor Yellow
    }
}

# -- 8f-ii. Coverage history writer
if ($coverageResult -ne $null -and $coverageResult.enabled -eq $true -and $ShotsDir -ne "") {
    $historyPath = Join-Path $ShotsDir "coverage-history.json"
    $maxHistoryEntries = 20

    # Buat entry baru
    $buildId = $null
    # Cek berbagai lokasi build_id/build yang umum digunakan
    if ($gameState -ne $null) {
        # Format 1: game_state.build (contoh: "slice-0.22")
        if ($gameState.PSObject.Properties.Name -contains "build" -and
            $gameState.build -ne $null) {
            $buildId = $gameState.build
        }
        # Format 2: game_state.build_id
        elseif ($gameState.PSObject.Properties.Name -contains "build_id" -and
            $gameState.build_id -ne $null) {
            $buildId = $gameState.build_id
        }
        # Format 3: game_state.world.build_id
        elseif ($gameState.PSObject.Properties.Name -contains "world" -and
            $gameState.world -ne $null -and
            $gameState.world.PSObject.Properties.Name -contains "build_id" -and
            $gameState.world.build_id -ne $null) {
            $buildId = $gameState.world.build_id
        }
        # Format 4: game_state.version
        elseif ($gameState.PSObject.Properties.Name -contains "version" -and
            $gameState.version -ne $null) {
            $buildId = $gameState.version
        }
    }

    $newEntry = [ordered]@{
        timestamp    = $ts_end.ToString("yyyy-MM-dd HH:mm:ss")
        build_id     = $buildId
        known_screens = @($coverageResult.known_screens)
        covered      = @($coverageResult.covered)
        uncovered    = @($coverageResult.uncovered)
        coverage_pct = $coverageResult.coverage_pct
        png_count    = $allPng.Count
    }

    # Load history yang ada atau buat baru
    $history = $null
    if (Test-Path -LiteralPath $historyPath) {
        try {
            $history = Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json
        } catch {
            $history = $null
        }
    }

    if ($history -eq $null) {
        $history = [PSCustomObject]@{
            schema_version = "1.0"
            max_entries    = $maxHistoryEntries
            entries        = @()
        }
    }

    # Tambah entry baru
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $history.entries) { $entries.Add($e) }
    $entries.Add($newEntry)

    # Prune: simpan hanya max_entries terbaru
    while ($entries.Count -gt $maxHistoryEntries) {
        $entries.RemoveAt(0)
    }

    # Hitung summary
    $allPcts = @($entries | Where-Object { $_.coverage_pct -ne $null } | ForEach-Object { [double]$_.coverage_pct })
    $avgPct  = if ($allPcts.Count -gt 0) { [math]::Round(($allPcts | Measure-Object -Average).Average, 1) } else { $null }

    # Persistently uncovered: screen yang uncovered di 3 run terakhir
    $last3 = @($entries | Select-Object -Last 3)
    $persistentUncovered = @()
    if ($last3.Count -eq 3) {
        $first3Uncovered = @($last3[0].uncovered)
        foreach ($screen in $first3Uncovered) {
            $inAll = $true
            foreach ($entry in $last3) {
                if ($entry.uncovered -notcontains $screen) { $inAll = $false; break }
            }
            if ($inAll) { $persistentUncovered += $screen }
        }
    }

    $lastFullCoverage = $null
    foreach ($e in ($entries | Sort-Object { $_.timestamp } -Descending)) {
        if ($e.coverage_pct -eq 100.0) { $lastFullCoverage = $e.timestamp; break }
    }

    $summary = [ordered]@{
        total_runs              = $entries.Count
        avg_coverage_pct        = $avgPct
        persistently_uncovered  = @($persistentUncovered)
        last_full_coverage      = $lastFullCoverage
    }

    $historyObj = [ordered]@{
        schema_version = "1.0"
        max_entries    = $maxHistoryEntries
        entries        = @($entries)
        summary        = $summary
    }

    try {
        $historyObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $historyPath -Encoding UTF8
        Write-Step "Coverage history: $($entries.Count) entries disimpan ($historyPath)"

        # Warn jika ada persistently uncovered
        if ($persistentUncovered.Count -gt 0) {
            Write-Warn "Persistently uncovered (3 run terakhir): $($persistentUncovered -join ', ')"
            Write-Host "[shot]      Tambahkan screen ini ke _shot_tour() untuk menutup gap" -ForegroundColor Yellow
        }
    } catch {
        Write-Warn "Gagal menulis coverage-history.json: $_"
    }
}

$ts_label = $ts_end.ToString("yyyy-MM-dd HH:mm:ss")
Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "[shot] Selesai pada $ts_label ($elapsed detik)"      -ForegroundColor Cyan
Write-Host "[shot] $($allPng.Count) file PNG di:"                -ForegroundColor Cyan
Write-Host "       $ShotsDir"                                     -ForegroundColor White
Write-Host "[shot] Telemetry fase: $telemetryPhase" -ForegroundColor $(
    switch ($telemetryPhase) {
        "mature"     { "Green"  }
        "developing" { "Cyan"   }
        default      { "Yellow" }
    }
)
if ($telemetryPhase -eq "prototype") {
    Write-Host "[shot]   -> game_state.json belum ada. Untuk fase developing/mature:" -ForegroundColor Yellow
    Write-Host "[shot]      game tulis data ke user://shots/game_state.json saat --shot" -ForegroundColor Yellow
} elseif ($telemetryPhase -eq "developing") {
    Write-Host "[shot]   -> Tambahkan game_state.json writer di _shot_tour() untuk fase mature" -ForegroundColor Cyan
}
if ($baselineAge -ne $null) {
    if ($baselineAge -gt 3) {
        Write-Host "[shot] WARN Baseline terakhir diupdate $baselineAge hari lalu — jalankan /baseline set jika ada perubahan visual intentional" -ForegroundColor Yellow
    } else {
        Write-Host "[shot] Baseline: diupdate $baselineAge hari lalu" -ForegroundColor Green
    }
} else {
    Write-Host "[shot] Baseline: belum ada — jalankan /baseline set setelah build pertama stabil" -ForegroundColor Yellow
}
Write-Host ""
foreach ($f in $allPng) {
    $size = [math]::Round($f.Length / 1024, 1)
    Write-Host "  $($f.Name.PadRight(35)) $size KB" -ForegroundColor Gray
}
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
