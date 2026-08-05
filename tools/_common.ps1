<#
.SYNOPSIS
    Fungsi deteksi environment bersama, dipakai oleh beberapa tool di tools/.

.DESCRIPTION
    Dot-source file ini (". $PSScriptRoot\_common.ps1"), bukan module -- konsisten
    dengan konvensi tools/ yang lain. File ini HANYA berisi definisi fungsi, tidak
    ada statement top-level (tidak set Set-StrictMode/$ErrorActionPreference di sini --
    dot-sourcing berjalan di scope pemanggil, jadi itu akan diam-diam mengubah state
    sesi pemanggil).

    Resolve-GodotExecutable dan Resolve-ImageMagick TIDAK PERNAH memanggil exit atau
    fungsi Write-Fail -- kebijakan hard-fail vs warn-and-continue tetap keputusan
    masing-masing pemanggil. Kedua fungsi mengembalikan string kosong "" jika tidak
    ketemu, atau path yang valid jika ketemu.

    Jika parameter sudah diisi eksplisit (non-empty), fungsi mengembalikannya apa
    adanya tanpa validasi Test-Path -- validasi tetap tanggung jawab pemanggil,
    konsisten dengan perilaku lama di tiap tool.
#>

function Resolve-GodotExecutable {
    param([string]$GodotExe = "")

    if ($GodotExe -ne "") { return $GodotExe }

    $candidates = @(
        "C:\Godot\Godot_v4.7-stable_win64_console.exe",
        "C:\Godot\Godot_v4.7-stable_win64.exe",
        "C:\Godot\godot.exe",
        "C:\Program Files\Godot\Godot_v4.7-stable_win64_console.exe",
        "C:\Program Files\Godot\Godot.exe",
        "C:\Program Files\Godot\godot.exe",
        "C:\Program Files (x86)\Godot\godot.exe",
        "$env:LOCALAPPDATA\Programs\Godot\godot.exe"
    )

    # Pencarian version-agnostic di lokasi instalasi umum, didahulukan atas daftar statis.
    #
    # Daftar statis di atas menyebut 4.7 secara eksplisit. Tanpa pencarian ini, pengguna
    # dengan Godot 4.3/4.4/4.5 yang namanya berversi -- dan tidak ada di PATH -- tidak akan
    # terdeteksi sama sekali. Nama file Godot memang selalu memuat nomor versi, jadi daftar
    # statis tidak akan pernah cukup.
    #
    # Build "_console" didahulukan dengan sengaja: shot-harness membaca stdout Godot, dan
    # build non-console di Windows tidak menyediakannya.
    $searchDirs = @(
        "C:\Godot",
        "C:\Program Files\Godot",
        "C:\Program Files (x86)\Godot",
        "$env:LOCALAPPDATA\Programs\Godot"
    )
    $globbed = @()
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $exes = @(Get-ChildItem -LiteralPath $dir -Filter "*.exe" -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*odot*" })
        if ($exes.Count -eq 0) { continue }
        # Nama diurut menurun supaya versi tertinggi menang (v4.7 > v4.4 > v4.3)
        $console = @($exes | Where-Object { $_.Name -like "*console*" } | Sort-Object Name -Descending)
        $plain   = @($exes | Where-Object { $_.Name -notlike "*console*" } | Sort-Object Name -Descending)
        $globbed += @($console | ForEach-Object { $_.FullName })
        $globbed += @($plain   | ForEach-Object { $_.FullName })
    }
    if ($globbed.Count -gt 0) { $candidates = $globbed + $candidates }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    foreach ($cmd in @("godot", "godot4", "godot.exe", "godot4.exe")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }

    return ""
}

function Resolve-ImageMagick {
    param([string]$ImageMagick = "")

    if ($ImageMagick -ne "") { return $ImageMagick }

    foreach ($cmd in @("magick", "compare")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found -and $found.Source -ne "") { return $found.Source }
    }

    $globPaths = @(
        "C:\Program Files\ImageMagick-7*\magick.exe",
        "C:\Program Files\ImageMagick-6*\compare.exe"
    )
    foreach ($g in $globPaths) {
        $found = Get-Item $g -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return ""
}

# Memetakan user:// milik project Godot ke path nyata di disk.
#
# Nama folder TIDAK boleh ditebak dari nama direktori project -- Godot memakai
# config/name dari project.godot, dan itu sering berbeda jauh. Contoh nyata dari
# game validasi: direktori "godot-open-rts" -> config/name "Open RTS", direktori
# "bread-adventure" -> "Bread Adventure Open". Menebak dari nama folder hanya
# kebetulan benar kalau keduanya sama.
#
# Dua bentuk lokasi:
#   config/use_custom_user_dir=true  -> %APPDATA%\<custom_user_dir_name>\shots
#   selain itu                       -> %APPDATA%\Godot\app_userdata\<config/name>\shots
#
# Mengembalikan hashtable supaya pemanggil yang ingin memberi tahu user (mis.
# "custom user dir terdeteksi") tidak perlu membaca ulang project.godot sendiri.
function Get-GodotUserDirInfo {
    param([string] $ProjectPath)

    $info = [ordered]@{
        ProjectName   = ""
        UsesCustomDir = $false
        CustomDirName = ""
        SafeName      = ""
        Sanitized     = $false
        ShotsDir      = ""
    }

    $projectGodot = Join-Path $ProjectPath "project.godot"
    if (Test-Path -LiteralPath $projectGodot) {
        try {
            $content = Get-Content -LiteralPath $projectGodot -Raw -Encoding UTF8
            if ($content -match 'config/name="([^"]+)"') {
                $info.ProjectName   = $Matches[1]
                $info.UsesCustomDir = [bool]($content -match 'config/use_custom_user_dir=true')
                if ($info.UsesCustomDir -and $content -match 'config/custom_user_dir_name="([^"]+)"') {
                    $info.CustomDirName = $Matches[1]
                }

                if ($info.UsesCustomDir -and $info.CustomDirName -ne "") {
                    $rawName    = $info.CustomDirName
                    $safe       = $rawName -replace '[\\/:*?"<>|]', '_'
                    $candidates = @("$env:APPDATA\$safe\shots")
                } else {
                    $rawName    = $info.ProjectName
                    $safe       = $rawName -replace '[\\/:*?"<>|]', '_'
                    # Varian huruf kecil 'godot' ikut dicek: sebagian instalasi/OS
                    # menghasilkan casing berbeda untuk direktori ini.
                    $candidates = @(
                        "$env:APPDATA\Godot\app_userdata\$safe\shots",
                        "$env:APPDATA\godot\app_userdata\$safe\shots"
                    )
                }
                $info.SafeName  = $safe
                $info.Sanitized = ($safe -ne $rawName)

                foreach ($c in $candidates) {
                    if (Test-Path -LiteralPath $c) { $info.ShotsDir = $c; break }
                }
                if ($info.ShotsDir -eq "") { $info.ShotsDir = $candidates[0] }
            }
        } catch { }
    }

    # Tanpa project.godot yang bisa dibaca (atau tanpa config/name), jatuh ke
    # <ProjectPath>\shots -- project non-Godot atau layout kustom.
    if ($info.ShotsDir -eq "") { $info.ShotsDir = Join-Path $ProjectPath "shots" }
    return $info
}

function Resolve-GodotShotsDir {
    param([string] $ProjectPath)
    return (Get-GodotUserDirInfo -ProjectPath $ProjectPath).ShotsDir
}


## Jalankan ImageMagick dan kembalikan stdout-nya (string), atau "" kalau gagal.
## Dipakai bersama oleh seluruh pengukuran gambar supaya pola pemanggilannya satu saja.
function Invoke-Magick {
    # JANGAN menamai parameter ini $Args -- itu variabel OTOMATIS PowerShell, dan
    # membayanginya membuat pengikatan parameter gagal diam-diam: setiap pemanggilan
    # mengembalikan string kosong sehingga seluruh pengukuran melaporkan -1.
    param([string] $Exe, [string] $MagickArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = $MagickArgs
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    try {
        $p    = [System.Diagnostics.Process]::Start($psi)
        $so   = $p.StandardOutput.ReadToEnd()
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { return "" }
        return $so.Trim()
    } catch { return "" }
}


## Kotak batas (bounding box) area yang berubah, plus berapa persen luas frame yang
## dicakupnya. Ini pembeda paling murah antara dua jenis perubahan yang sangat berbeda
## artinya tetapi menghasilkan angka persen yang mirip:
##   - perubahan GLOBAL (frame bergeser, tema berubah) -> kotaknya nyaris seluruh frame
##   - perubahan KONTEN (satu tombol, satu label)      -> kotaknya kecil dan terpusat
## Tanpa ini, "berubah 24%" tidak memberi tahu apakah yang berubah seluruh layar atau
## satu panel -- dan itu perbedaan antara "screen-shake" dan "regresi sungguhan".
function Get-ImageChangeBBox {
    param([string] $PathA, [string] $PathB, [string] $ImageMagickExe)

    $out = [ordered]@{ bbox = ""; coverage_pct = -1.0 }
    if (-not (Test-Path -LiteralPath $PathA)) { return $out }
    if (-not (Test-Path -LiteralPath $PathB)) { return $out }

    $dim = Invoke-Magick -Exe $ImageMagickExe -MagickArgs "identify -format `"%w %h`" `"$PathA`""
    if ($dim -notmatch "^(\d+)\s+(\d+)$") { return $out }
    $fw = [int]$Matches[1]; $fh = [int]$Matches[2]

    # %@ = kotak batas area non-hitam pada citra selisih yang sudah di-threshold
    $bb = Invoke-Magick -Exe $ImageMagickExe -MagickArgs (
        "`"$PathA`" `"$PathB`" -colorspace sRGB -alpha off -compose difference -composite " +
        "-threshold 0 -separate -evaluate-sequence max -format `"%@`" info:")
    if ($bb -notmatch "^(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$") { return $out }

    $bw = [int]$Matches[1]; $bh = [int]$Matches[2]

    # Kotak 0x0 = kasus degenerate: %@ menghitung batas dengan memangkas tepi yang seragam,
    # dan ketika SELURUH frame berubah tidak ada tepi tersisa untuk dipangkas sehingga
    # hasilnya menyusut ke nol. Artinya justru kebalikan dari "tidak ada perubahan" --
    # ini cakupan penuh. Tanpa penanganan ini, perubahan global (mis. tema atau kecerahan
    # berubah) terbaca sebagai cakupan 0% dan salah digolongkan sebagai perubahan terpusat.
    # Kasus lain sudah benar apa adanya, termasuk perubahan yang menempel tepat di pojok.
    if ($bw -eq 0 -or $bh -eq 0) {
        $out.bbox = "${fw}x${fh}+0+0"
        $out.coverage_pct = 100.0
        return $out
    }

    $out.bbox = $bb
    if ($fw -gt 0 -and $fh -gt 0) {
        $out.coverage_pct = [math]::Round((($bw * $bh) / [double]($fw * $fh)) * 100, 2)
    }
    return $out
}


## Cari pergeseran (dx,dy) yang paling menjelaskan perbedaan dua gambar.
##
## Kenapa perlu: screen-shake menggeser SELURUH frame beberapa pixel. Setiap tepi glif ikut
## berubah, sehingga persentase pixel melonjak tinggi padahal isinya identik. Tanpa
## pemeriksaan ini, satu getaran kamera tidak bisa dibedakan dari regresi sungguhan.
##
## Pencarian dibuat SEPARABEL (dx dulu, lalu dy pada dx terbaik): 2*(2R+1) pemanggilan,
## bukan (2R+1)^2. Pada R=8 itu 34 kali, bukan 289.
##
## Kedua gambar di-crop ke bagian dalam sebesar R pixel di tiap sisi SEBELUM dibandingkan.
## Tanpa crop, -roll membungkus pixel dari sisi seberang dan pita bungkusan itu sendiri
## terhitung sebagai perbedaan -- biasnya selalu menguntungkan pergeseran kecil, sehingga
## pergeseran besar tidak pernah ditemukan.
function Find-ImageShift {
    param(
        [string] $PathA,           # baseline -- ini yang digeser
        [string] $PathB,           # current
        [string] $ImageMagickExe,
        [int]    $MaxShift = 8
    )

    $res = [ordered]@{ dx = 0; dy = 0; residual_pct = -1.0; origin_pct = -1.0 }
    $dim = Invoke-Magick -Exe $ImageMagickExe -MagickArgs "identify -format `"%w %h`" `"$PathA`""
    if ($dim -notmatch "^(\d+)\s+(\d+)$") { return $res }
    $fw = [int]$Matches[1]; $fh = [int]$Matches[2]
    $m  = $MaxShift
    $cw = $fw - 2 * $m; $ch = $fh - 2 * $m
    if ($cw -le 8 -or $ch -le 8) { return $res }
    $crop = "${cw}x${ch}+${m}+${m}"

    function Measure-At {
        param([int] $DX, [int] $DY)
        $sx = if ($DX -ge 0) { "+$DX" } else { "$DX" }
        $sy = if ($DY -ge 0) { "+$DY" } else { "$DY" }
        $a = "`"$PathA`" -roll ${sx}${sy} -crop $crop +repage"
        $b = "`"$PathB`" -crop $crop +repage"
        $o = Invoke-Magick -Exe $ImageMagickExe -MagickArgs (
            "( $a ) ( $b ) -colorspace sRGB -alpha off -compose difference -composite " +
            "-threshold 0 -separate -evaluate-sequence max -format `"%[fx:mean]`" info:")
        if ($o -match "^([\d.]+(?:[eE][+\-]?\d+)?)$") { return [math]::Round([double]$o * 100, 3) }
        return -1.0
    }

    $origin = Measure-At -DX 0 -DY 0
    if ($origin -lt 0) { return $res }
    $res.origin_pct = $origin

    # Coordinate descent, BUKAN satu lintasan separabel.
    #
    # Satu lintasan (scan dx pada dy=0, lalu dy pada dx terbaik) gagal begitu KEDUA sumbu
    # bergeser: saat dy masih meleset, tidak ada nilai dx yang benar-benar menyelaraskan,
    # sehingga minimum lintasan pertama jatuh di tempat yang salah dan lintasan kedua tidak
    # bisa lagi membetulkannya. Terukur: pergeseran nyata (+5,-2) terbaca (+3,-2) dengan
    # residual 31.8% -- ditemukan karena diuji dengan pergeseran yang jawabannya diketahui.
    # Mengulang kedua scan bergantian sampai tidak ada perbaikan menutup celah itu dengan
    # biaya yang tetap linier, bukan kuadratik seperti pencarian 2D penuh.
    $bestDx = 0; $bestDy = 0; $bestVal = $origin
    for ($round = 0; $round -lt 4; $round++) {
        $improved = $false
        for ($d = -$m; $d -le $m; $d++) {
            if ($d -eq $bestDx) { continue }
            $v = Measure-At -DX $d -DY $bestDy
            if ($v -ge 0 -and $v -lt $bestVal) { $bestVal = $v; $bestDx = $d; $improved = $true }
        }
        for ($d = -$m; $d -le $m; $d++) {
            if ($d -eq $bestDy) { continue }
            $v = Measure-At -DX $bestDx -DY $d
            if ($v -ge 0 -and $v -lt $bestVal) { $bestVal = $v; $bestDy = $d; $improved = $true }
        }
        if (-not $improved) { break }
    }

    $res.dx = $bestDx; $res.dy = $bestDy; $res.residual_pct = $bestVal
    return $res
}


## Persentase pixel yang benar-benar berbeda antara dua gambar (0..100), atau -1 kalau gagal.
##
## JANGAN ganti dengan `compare -metric AE`. Pada build Q16-HDRI, AE mengembalikan jumlah
## magnitudo ter-skala quantum dan bukan cacah pixel: 500 pixel berbeda menghasilkan
## 500 x 65535 = 32.767.500, sehingga rasio membengkak lalu ter-clamp ke 100 dan SETIAP
## gambar yang tidak identik dilaporkan "100% berubah".
##
## Urutan operator di bawah semuanya load-bearing:
##   -colorspace sRGB di DEPAN  : menyamakan colorspace kedua input lebih dulu; tanpa ini
##                                baseline Gray vs current sRGB terbaca identik.
##   -threshold 0               : bekerja per channel, menandai setiap selisih sekecil apa pun.
##   -separate -evaluate-sequence max : sebuah pixel dihitung berbeda bila ADA channel yang
##                                berbeda, sehingga perbedaan murni warna tidak hilang saat
##                                citra selisih diratakan menjadi Gray.
function Get-ImageChangePercent {
    param(
        [string] $PathA,
        [string] $PathB,
        [string] $ImageMagickExe
    )
    if (-not (Test-Path -LiteralPath $PathA)) { return -1.0 }
    if (-not (Test-Path -LiteralPath $PathB)) { return -1.0 }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $ImageMagickExe
    $psi.Arguments = "`"$PathA`" `"$PathB`" -colorspace sRGB -alpha off " +
                     "-compose difference -composite -threshold 0 " +
                     "-separate -evaluate-sequence max -format `"%[fx:mean]`" info:"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    try {
        $p    = [System.Diagnostics.Process]::Start($psi)
        $so   = $p.StandardOutput.ReadToEnd()
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { return -1.0 }
        if ($so.Trim() -match "^([\d.]+(?:[eE][+\-]?\d+)?)$") {
            return [math]::Round([double]$Matches[1] * 100, 3)
        }
    } catch { }
    return -1.0
}
