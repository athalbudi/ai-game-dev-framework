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

.PARAMETER InstallAgentRules
    Pasang aturan agent global supaya framework ini dikenali dari project game manapun,
    bukan hanya dari dalam repo ini. OPT-IN -- default TIDAK aktif, karena menulis ke
    direktori config pribadi pengguna harus jadi keputusan sadar.

    Yang disentuh (hanya yang direktorinya sudah ada -- tidak pernah membuat direktori
    agent yang tidak dipakai pengguna):
      - ~/.kilocode/rules/gamedev-framework.md   (file terpisah, aditif)
      - ~/.claude/CLAUDE.md                       (blok bertanda BEGIN/END)

    Isi di luar penanda tidak pernah disentuh, dan menjalankan ulang bersifat idempoten.

.PARAMETER UninstallAgentRules
    Cabut kembali apa yang dipasang -InstallAgentRules, lalu keluar tanpa menjalankan
    bootstrap. Teks pengguna di luar penanda tetap utuh.

.EXAMPLE
    & ".\setup.ps1"
    & ".\setup.ps1" -DryRun
    & ".\setup.ps1" -Full
    & ".\setup.ps1" -InstallAgentRules
    & ".\setup.ps1" -UninstallAgentRules
#>

[CmdletBinding()]
param(
    [string] $GodotExe              = "",
    [string] $ImageMagickExe        = "",
    [string] $GameProjectScriptsDir = "",
    [switch] $DryRun,
    [switch] $Full,
    [switch] $SkipHealthCheck,
    [switch] $InstallAgentRules,
    [switch] $UninstallAgentRules
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

# ── Aturan agent global ────────────────────────────────────────────────────────
# Penanda dipakai untuk menyisipkan ke file yang DIMILIKI pengguna (mis. ~/.claude/CLAUDE.md).
# Tanpa penanda, satu-satunya cara update adalah menimpa seluruh file -- yang berarti
# menghancurkan isi pribadi pengguna. Dengan penanda, kita hanya menyentuh blok kita sendiri.
$agentMarkBegin = "<!-- BEGIN ai-game-dev-framework (dikelola setup.ps1 -- jangan edit manual) -->"
$agentMarkEnd   = "<!-- END ai-game-dev-framework -->"

function Read-TextFileOrEmpty {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFileNoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Sisipkan/perbarui blok bertanda. Memakai IndexOf + Substring, BUKAN -replace regex:
# isi aturan bisa mengandung '$' yang akan ditafsirkan sebagai grup pengganti oleh -replace.
function Set-MarkedBlock {
    param([string]$Content, [string]$Block)
    $iB = $Content.IndexOf($agentMarkBegin)
    $iE = $Content.IndexOf($agentMarkEnd)
    if ($iB -ge 0 -and $iE -gt $iB) {
        $before = $Content.Substring(0, $iB)
        $after  = $Content.Substring($iE + $agentMarkEnd.Length)
        return ($before + $Block + $after)
    }
    if ($Content.Trim() -eq "") { return ($Block + "`n") }
    return ($Content.TrimEnd() + "`n`n" + $Block + "`n")
}

function Remove-MarkedBlock {
    param([string]$Content)
    $iB = $Content.IndexOf($agentMarkBegin)
    $iE = $Content.IndexOf($agentMarkEnd)
    if ($iB -lt 0 -or $iE -le $iB) { return $Content }   # tidak ada blok kita -- jangan sentuh
    $before = $Content.Substring(0, $iB)
    $after  = $Content.Substring($iE + $agentMarkEnd.Length)
    $joined = ($before.TrimEnd() + "`n" + $after.TrimStart()).Trim()
    if ($joined -eq "") { return "" }
    return ($joined + "`n")
}

# Status penanda di sebuah file. "malformed" = BEGIN/END tidak berpasangan (mis. pengguna
# tak sengaja menghapus salah satunya saat edit manual). Dalam kondisi itu kita TIDAK BOLEH
# menebak batas blok: IndexOf(BEGIN) yang pertama dipasangkan dengan END milik blok lain
# akan melahap teks pengguna di antaranya.
function Get-MarkerState {
    param([string]$Content)
    $nB = ([regex]::Matches($Content, [regex]::Escape($agentMarkBegin))).Count
    $nE = ([regex]::Matches($Content, [regex]::Escape($agentMarkEnd))).Count
    if ($nB -eq 0 -and $nE -eq 0) { return "none" }
    if ($nB -eq 1 -and $nE -eq 1 -and ($Content.IndexOf($agentMarkEnd) -gt $Content.IndexOf($agentMarkBegin))) {
        return "ok"
    }
    return "malformed"
}

function Get-AgentTargets {
    # Hanya laporkan agent yang direktori config-nya SUDAH ada. Membuat ~/.claude atau
    # ~/.kilocode untuk pengguna yang tidak memakainya cuma menaruh sampah di home mereka.
    $home_ = $env:USERPROFILE
    $t = @()
    $kilocodeDir = Join-Path $home_ ".kilocode"
    if (Test-Path -LiteralPath $kilocodeDir) {
        $t += [pscustomobject]@{
            Name = "Kilo Code"
            Path = (Join-Path $kilocodeDir "rules\gamedev-framework.md")
            Mode = "file"
        }
    }
    $claudeDir = Join-Path $home_ ".claude"
    if (Test-Path -LiteralPath $claudeDir) {
        $t += [pscustomobject]@{
            Name = "Claude Code"
            Path = (Join-Path $claudeDir "CLAUDE.md")
            Mode = "block"
        }
    }
    return @($t)
}

function Install-AgentRules {
    param([string]$RulesSourcePath)
    if (-not (Test-Path -LiteralPath $RulesSourcePath)) {
        Write-Bad "File aturan tidak ditemukan: $RulesSourcePath"
        return @{ Installed = 0; Failed = 1 }
    }
    $rules   = ([System.IO.File]::ReadAllText($RulesSourcePath)).Trim()
    $block   = $agentMarkBegin + "`n" + $rules + "`n" + $agentMarkEnd
    # @(...) di sisi pemanggil WAJIB: di PS 5.1 array yang di-return fungsi ter-unroll --
    # 0 elemen jadi $null dan 1 elemen jadi objek tunggal, sehingga .Count melempar
    # PropertyNotFoundException di bawah StrictMode. Konfigurasi satu-agent adalah kasus
    # paling umum di dunia nyata, jadi jalur ini harus benar.
    $targets = @(Get-AgentTargets)
    if ($targets.Count -eq 0) {
        Write-Warn "Tidak ada direktori config agent terdeteksi (~/.kilocode atau ~/.claude)"
        Write-Warn "Pasang manual: salin isi $RulesSourcePath ke file aturan global agent Anda"
        return @{ Installed = 0; Failed = 0 }
    }
    $installed = 0
    $failed    = 0
    foreach ($t in $targets) {
        if ($t.Mode -eq "file") {
            # Direktori rules Kilo memang multi-file -- file sendiri, tidak perlu penanda.
            Write-TextFileNoBom -Path $t.Path -Content ($rules + "`n")
            Write-Ok ("$($t.Name): " + $t.Path)
            $installed++
            continue
        }
        $existing = Read-TextFileOrEmpty -Path $t.Path
        if ((Get-MarkerState -Content $existing) -eq "malformed") {
            Write-Bad ("$($t.Name): penanda BEGIN/END tidak berpasangan di " + $t.Path)
            Write-Bad "      File TIDAK diubah. Rapikan manual dulu -- sisakan tepat satu pasang"
            Write-Bad "      BEGIN/END, atau hapus keduanya -- lalu jalankan lagi."
            Write-Bad "      Menebak batas blok di sini berisiko menghapus catatan pribadi Anda."
            $failed++
            continue
        }
        Write-TextFileNoBom -Path $t.Path -Content (Set-MarkedBlock -Content $existing -Block $block)
        Write-Ok ("$($t.Name): " + $t.Path)
        $installed++
    }
    return @{ Installed = $installed; Failed = $failed }
}

function Uninstall-AgentRules {
    $targets = @(Get-AgentTargets)   # lihat catatan unrolling di Install-AgentRules
    $touched = 0
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { continue }
        if ($t.Mode -eq "file") {
            Remove-Item -LiteralPath $t.Path -Force
            Write-Ok ("dihapus: " + $t.Path)
            $touched++
        } else {
            $existing = Read-TextFileOrEmpty -Path $t.Path
            if ((Get-MarkerState -Content $existing) -eq "malformed") {
                Write-Bad ("penanda tidak berpasangan di " + $t.Path + " -- file tidak diubah")
                Write-Bad "      Hapus blok framework secara manual agar aman."
                continue
            }
            $stripped = Remove-MarkedBlock -Content $existing
            if ($stripped -ne $existing) {
                Write-TextFileNoBom -Path $t.Path -Content $stripped
                Write-Ok ("blok dicabut, isi lain dipertahankan: " + $t.Path)
                $touched++
            }
        }
    }
    if ($touched -eq 0) { Write-Warn "Tidak ada aturan agent terpasang yang ditemukan" }
    return $touched
}

# -- Mode uninstall: berdiri sendiri, tidak menjalankan bootstrap ----------------
if ($UninstallAgentRules) {
    Write-Host ""
    if ($InstallAgentRules) {
        Write-Bad "-InstallAgentRules dan -UninstallAgentRules diberikan bersamaan -- maksudnya ambigu"
        Write-Bad "Jalankan salah satu saja."
        exit 1
    }
    Write-Host "[setup] Mencabut aturan agent global..." -ForegroundColor Cyan
    $null = Uninstall-AgentRules
    Write-Host ""
    exit 0
}

$totalSteps = if ($InstallAgentRules) { 10 } else { 9 }

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
    if ($InstallAgentRules) {
        Write-Warn "-InstallAgentRules dilewati karena -DryRun aktif (tidak ada file config yang ditulis)"
    }
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
        # --untracked-files=no disengaja: "dirty" di sini berarti "ada modifikasi lokal
        # pada file framework yang bisa hilang saat sync ulang". File untracked yang tidak
        # berhubungan (mis. direktori config editor) bukan itu, dan kalau ikut dihitung
        # stamp akan selamanya melaporkan dirty=true walau semua sudah ter-commit.
        $statusOut = git status --porcelain --untracked-files=no 2>$null
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

# -- 10. (opsional) Pasang aturan agent global -----------------------------------
if ($InstallAgentRules) {
    Write-Step 10 $totalSteps "Pasang aturan agent global (opt-in)"
    $rulesSrc  = Join-Path $repoRoot "agent-rules\gamedev-framework.md"
    $ruleStats = Install-AgentRules -RulesSourcePath $rulesSrc
    if ($ruleStats.Failed -gt 0) {
        Write-Bad "$($ruleStats.Failed) target gagal -- lihat pesan di atas"
        exit 1
    }
    # Jangan klaim "terpasang" kalau tidak ada satu file pun yang ditulis.
    if ($ruleStats.Installed -eq 0) {
        Write-Warn "Tidak ada aturan agent yang dipasang (tidak ada agent terdeteksi di mesin ini)"
    } else {
        Write-Ok "$($ruleStats.Installed) file aturan diperbarui -- cabut dengan: setup.ps1 -UninstallAgentRules"
    }
}

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
