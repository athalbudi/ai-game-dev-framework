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

    # Cari versi apapun di C:\Godot\ -- ambil terbaru, coba lebih dulu dari daftar statis
    if (Test-Path "C:\Godot") {
        $found = Get-ChildItem "C:\Godot" -Filter "*win64_console.exe" -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending | Select-Object -First 1
        if ($found) { $candidates = @($found.FullName) + $candidates }
    }

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
            $content = Get-Content -LiteralPath $projectGodot -Raw
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
