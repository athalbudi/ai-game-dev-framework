<#
.SYNOPSIS
    Bootstrap satu-langkah untuk AI-Assisted Game Development Framework.
    Jalankan ini sekali di awal (dari root repo) sebelum mulai memakai framework --
    baik oleh manusia maupun AI coding agent (Claude Code, Kilo Code, dll) yang
    membaca AGENTS.md.

.DESCRIPTION
    Urutan:
      1. Cek versi PowerShell
      2. Unblock semua *.ps1 di repo (mengatasi Mark-of-the-Web dari ZIP GitHub)
      3. Deteksi Godot
      4. Deteksi ImageMagick
      5. Pastikan ~/.config/kilo ada
      6. Healthcheck pra-sync (doctor.ps1 terhadap repo -- deteksi clone/download tidak lengkap)
      7. Jalankan sync.ps1 (menyalin tools/templates ke ~/.config/kilo)
      8. Healthcheck pasca-sync (doctor.ps1 terhadap hasil deploy)
      9. Tulis ~/.config/kilo/version.json

    Urutan 8 sebelum 9 disengaja. version.json adalah sinyal yang dibaca hook AGENTS.md untuk
    memutuskan "framework sudah ter-bootstrap atau belum". Kalau file itu ditulis sebelum
    verifikasi, instalasi yang gagal di langkah 8 akan meninggalkan stamp yang menyesatkan --
    agent berikutnya melanjutkan di atas instalasi rusak. Jadi: gagal = tidak ada stamp.

    Field "verified" di version.json bernilai false hanya jika -SkipHealthCheck dipakai,
    sehingga stamp tetap jujur tentang apa yang sebenarnya sudah dicek.

    Exit 0 = sync sukses + healthcheck pasca-sync CRITICAL lulus (atau -DryRun/-SkipHealthCheck).
    Exit 1 = ada kegagalan CRITICAL di langkah manapun.

.PARAMETER GodotExe
    Path ke Godot executable. Jika kosong, dicari otomatis.

.PARAMETER ImageMagickExe
    Path ke ImageMagick executable. Jika kosong, dicari otomatis.

.PARAMETER GameProjectScriptsDir
    Diteruskan ke sync.ps1 -- sync sekaligus ke scripts/ project game tertentu.

.PARAMETER DryRun
    Diteruskan ke sync.ps1. Berhenti setelah preview sync -- tidak menulis version.json
    atau menjalankan healthcheck pasca-sync (tidak ada yang baru untuk diverifikasi).

.PARAMETER Full
    Diteruskan ke doctor.ps1 -- jalankan juga golden-project run nyata (lebih lambat,
    tapi memverifikasi Godot benar-benar bisa menjalankan harness end-to-end).

.PARAMETER SkipHealthCheck
    Lewati healthcheck pra-sync dan pasca-sync. Untuk pengguna lanjutan yang hanya ingin
    sync cepat -- TIDAK direkomendasikan untuk setup pertama kali.

.EXAMPLE
    & ".\setup.ps1"
    & ".\setup.ps1" -DryRun
    & ".\setup.ps1" -Full
#>

[CmdletBinding()]
param(
    [string] $GodotExe              = "",
    [string] $ImageMagickExe        = "",
    [string] $GameProjectScriptsDir = "",
    [switch] $DryRun,
    [switch] $Full,
    [switch] $SkipHealthCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot   = $PSScriptRoot
$kiloConfig = Join-Path $env:USERPROFILE ".config\kilo"

$commonPs1 = Join-Path $repoRoot "tools\_common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    Write-Host "[setup] FAIL tools\_common.ps1 tidak ditemukan di $repoRoot" -ForegroundColor Red
    Write-Host "[setup]      Clone/download repo tampaknya tidak lengkap -- coba ambil ulang." -ForegroundColor Red
    exit 1
}
. $commonPs1

function Write-Step { param($n, $total, $msg) Write-Host "[setup] Langkah ${n}/${total}: $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "[setup] OK   $msg" -ForegroundColor Green  }
function Write-Warn { param($msg) Write-Host "[setup] WARN $msg" -ForegroundColor Yellow }
function Write-Bad  { param($msg) Write-Host "[setup] FAIL $msg" -ForegroundColor Red    }

$totalSteps = 9

Write-Host ""
Write-Host "[setup] ================================================" -ForegroundColor Cyan
Write-Host "[setup]  AI-Game-Dev-Framework -- Bootstrap" -ForegroundColor Cyan
Write-Host "[setup] ================================================" -ForegroundColor Cyan

# -- 1. Cek versi PowerShell -----------------------------------------------------
Write-Step 1 $totalSteps "Cek versi PowerShell"
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
    Write-Bad "PowerShell $psVersion terlalu lama -- framework butuh minimal 5.1"
    exit 1
} elseif ($psVersion.Major -ge 6) {
    Write-Warn "PowerShell $psVersion (pwsh/Core) terdeteksi -- framework diuji khusus di Windows PowerShell 5.1, sebagian tool mungkin berperilaku beda"
} else {
    Write-Ok "PowerShell $psVersion"
}

# -- 2. Unblock semua *.ps1 di repo ------------------------------------------------
Write-Step 2 $totalSteps "Unblock file .ps1 (jika di-download sebagai ZIP dari GitHub)"
try {
    Get-ChildItem -LiteralPath $repoRoot -Filter "*.ps1" -Recurse | Unblock-File -ErrorAction SilentlyContinue
    Write-Ok "Semua *.ps1 di-unblock"
} catch {
    Write-Warn "Gagal unblock beberapa file: $_"
}
$execPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($execPolicy -eq "Restricted") {
    Write-Warn "ExecutionPolicy CurrentUser = Restricted -- script tidak akan bisa dijalankan"
    Write-Warn "Jalankan ini lalu ulangi: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned"
}

# -- 3. Deteksi Godot ---------------------------------------------------------------
Write-Step 3 $totalSteps "Deteksi Godot"
if ($GodotExe -eq "") { $GodotExe = Resolve-GodotExecutable }
$godotFound = ($GodotExe -ne "") -and (Test-Path -LiteralPath $GodotExe)
if ($godotFound) {
    Write-Ok "Godot ditemukan: $GodotExe"
} else {
    Write-Warn "Godot tidak ditemukan. Download: https://godotengine.org/download/windows"
    Write-Warn "Setelah install, jalankan ulang setup.ps1 atau tools\doctor.ps1 untuk verifikasi"
}

# -- 4. Deteksi ImageMagick -----------------------------------------------------------
Write-Step 4 $totalSteps "Deteksi ImageMagick"
if ($ImageMagickExe -eq "") { $ImageMagickExe = Resolve-ImageMagick }
if ($ImageMagickExe -ne "" -and (Test-Path -LiteralPath $ImageMagickExe)) {
    Write-Ok "ImageMagick ditemukan: $ImageMagickExe"
} else {
    Write-Warn "ImageMagick tidak ditemukan -- visual-diff akan fallback ke MD5 hash comparison"
    Write-Warn "Install (opsional): https://imagemagick.org"
}

# -- 5. Pastikan ~/.config/kilo ada -------------------------------------------------
Write-Step 5 $totalSteps "Pastikan ~/.config/kilo ada"
if (-not (Test-Path -LiteralPath $kiloConfig)) {
    New-Item -ItemType Directory -Path $kiloConfig -Force | Out-Null
    Write-Ok "Dibuat: $kiloConfig"
} else {
    Write-Ok "Sudah ada: $kiloConfig"
}

# -- 6. Healthcheck pra-sync ------------------------------------------------------
$doctorPs1 = Join-Path $repoRoot "tools\doctor.ps1"
if ($SkipHealthCheck) {
    Write-Step 6 $totalSteps "Healthcheck pra-sync (dilewati -- -SkipHealthCheck)"
} else {
    Write-Step 6 $totalSteps "Healthcheck pra-sync (verifikasi repo lengkap sebelum sync)"
    # Sengaja TANPA -Full: cek pra-sync hanya perlu membuktikan repo utuh sebelum menyalin.
    # Golden-project run yang mahal dijalankan sekali saja, di cek pasca-sync (langkah 9),
    # karena yang benar-benar penting adalah artefak yang ter-deploy -- bukan salinan repo.
    & $doctorPs1 -KiloRoot $repoRoot -GodotExe $GodotExe -ImageMagickExe $ImageMagickExe
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "Healthcheck pra-sync gagal -- kemungkinan clone/download repo tidak lengkap"
        Write-Bad "Coba clone/download ulang repo, atau jalankan tools\doctor.ps1 -KiloRoot `"$repoRoot`" untuk detail"
        exit 1
    }
    Write-Ok "Healthcheck pra-sync lulus"
}

# -- 7. Jalankan sync.ps1 -----------------------------------------------------------
Write-Step 7 $totalSteps "Sync tools & template ke ~/.config/kilo"
$syncPs1  = Join-Path $repoRoot "sync.ps1"
$syncArgs = @{}
if ($DryRun) { $syncArgs["DryRun"] = $true }
if ($GameProjectScriptsDir -ne "") { $syncArgs["GameProjectScriptsDir"] = $GameProjectScriptsDir }
& $syncPs1 @syncArgs
if ($LASTEXITCODE -ne 0) {
    Write-Bad "sync.ps1 gagal -- lihat detail error di atas"
    exit 1
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[setup] ================================================" -ForegroundColor Cyan
    Write-Host "[setup]  DRY RUN selesai -- tidak ada perubahan yang ditulis" -ForegroundColor Cyan
    Write-Host "[setup] ================================================" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# -- 8. Healthcheck pasca-sync ---------------------------------------------------------
# HARUS sebelum version.json ditulis. version.json adalah sinyal "bootstrap terverifikasi
# sehat" yang dibaca hook AGENTS.md; kalau ditulis lebih dulu lalu healthcheck gagal, file
# itu tertinggal di disk dan agent berikutnya menyimpulkan instalasi rusak sebagai "siap".
$healthVerified = $false
if ($SkipHealthCheck) {
    Write-Step 8 $totalSteps "Healthcheck pasca-sync (dilewati -- -SkipHealthCheck)"
    Write-Warn "Stamp akan ditandai verified=false karena verifikasi dilewati"
} else {
    Write-Step 8 $totalSteps "Healthcheck pasca-sync (verifikasi hasil deploy)"
    $deployedDoctor = Join-Path $kiloConfig "tools\doctor.ps1"
    if (-not (Test-Path -LiteralPath $deployedDoctor)) {
        Write-Bad "doctor.ps1 tidak ditemukan di deployed ($deployedDoctor) -- sync tampaknya gagal menyalin file ini"
        Write-Bad "Ini indikasi bug, bukan kondisi sementara -- laporkan ke maintainer"
        exit 1
    }
    & $deployedDoctor -GodotExe $GodotExe -ImageMagickExe $ImageMagickExe -Full:$Full
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "Healthcheck pasca-sync gagal -- sync melapor sukses tapi hasil deploy rusak"
        Write-Bad "Ini indikasi bug, bukan kondisi sementara -- laporkan ke maintainer"
        Write-Bad "version.json TIDAK ditulis -- instalasi ini tidak boleh dianggap siap pakai"
        exit 1
    }
    Write-Ok "Healthcheck pasca-sync lulus"
    $healthVerified = $true
}

# -- 9. Tulis version.json (paling akhir) ----------------------------------------------
Write-Step 9 $totalSteps "Tulis version.json"
$versionFile      = Join-Path $repoRoot "VERSION"
$frameworkVersion = if (Test-Path -LiteralPath $versionFile) {
    (Get-Content -LiteralPath $versionFile -Raw).Trim()
} else {
    "unknown"
}

$gitCommit = "unknown"
$gitDirty  = $null
try {
    Push-Location $repoRoot
    $commitOut = git rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $commitOut) {
        $gitCommit = $commitOut.Trim()
        $statusOut = git status --porcelain 2>$null
        $gitDirty  = [bool]($statusOut -and ($statusOut.Trim() -ne ""))
    } else {
        Write-Warn "Tidak bisa membaca git commit -- bukan git checkout atau git tidak tersedia"
    }
} catch {
    Write-Warn "Tidak bisa membaca git commit: $_"
} finally {
    Pop-Location
}

$versionInfo = [ordered]@{
    stamp_schema_version = "1.0"
    framework_version    = $frameworkVersion
    git_commit           = $gitCommit
    git_dirty            = $gitDirty
    synced_at            = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    # false hanya jika -SkipHealthCheck dipakai. Keberadaan file ini berarti sync selesai;
    # field ini yang membedakan "sudah diverifikasi sehat" dari "belum pernah dicek".
    verified             = $healthVerified
    # Dicatat supaya tool/agent yang berjalan di project game lain (yang tidak tahu di mana
    # repo framework berada) bisa menemukan sumbernya untuk sync ulang di kemudian hari.
    repo_path            = $repoRoot
}
$versionJsonPath = Join-Path $kiloConfig "version.json"
$versionInfo | ConvertTo-Json | Set-Content -LiteralPath $versionJsonPath -Encoding UTF8
Write-Ok "Ditulis: $versionJsonPath"

Write-Host ""
if (-not $godotFound) {
    # Tanpa Godot, healthcheck tidak pernah memverifikasi template .gd -- jangan klaim "siap dipakai".
    Write-Host "[setup] ================================================" -ForegroundColor Yellow
    Write-Host "[setup]  Bootstrap selesai SEBAGIAN -- Godot belum terpasang." -ForegroundColor Yellow
    Write-Host "[setup]  File sudah ter-install, TAPI template .gd belum diverifikasi" -ForegroundColor Yellow
    Write-Host "[setup]  dan tool yang butuh Godot (shot-harness, scenario) belum bisa dipakai." -ForegroundColor Yellow
    Write-Host "[setup]  Install Godot -> https://godotengine.org/download/windows" -ForegroundColor Yellow
    Write-Host "[setup]  lalu jalankan ulang setup.ps1 untuk verifikasi penuh." -ForegroundColor Yellow
    Write-Host "[setup] ================================================" -ForegroundColor Yellow
} else {
    Write-Host "[setup] ================================================" -ForegroundColor Green
    Write-Host "[setup]  Bootstrap selesai. Framework siap dipakai." -ForegroundColor Green
    Write-Host "[setup] ================================================" -ForegroundColor Green
}
Write-Host ""

exit 0
