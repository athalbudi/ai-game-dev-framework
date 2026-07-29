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
