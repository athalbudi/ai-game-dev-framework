<#
.SYNOPSIS
    Scenario generation feedback loop otomatis untuk AI-assisted game development.
    Observe -> Generate -> Run -> Analyze -> Report dalam satu langkah.

.DESCRIPTION
    Script ini mengimplementasikan loop QA autonomous:
      1. OBSERVE  — jalankan shot harness, ambil screenshot + manifest
      2. GENERATE — invoke AI via Kilo /scenario generate (atau buat template)
      3. RUN      — jalankan scenario yang dihasilkan via harness --scenario
      4. ANALYZE  — baca scenario_result.json + diff-report.json
      5. REPORT   — tulis laporan JSON + ringkasan ke stdout

    Script ini TIDAK membutuhkan game state khusus — berjalan dari fase prototype.
    Semakin banyak data yang tersedia (game_state.json, baseline), semakin dalam analisisnya.

.PARAMETER ProjectPath
    Path ke folder project Godot. Default: direktori kerja saat ini.

.PARAMETER ScenarioName
    Nama scenario yang akan dijalankan. Jika kosong, gunakan smoke test default.
    Cari di <ProjectPath>\scenarios\<nama>.json

.PARAMETER GodotExe
    Path ke Godot executable. Jika kosong, dicari otomatis.

.PARAMETER Timeout
    Batas waktu harness dalam detik. Default: 120.

.PARAMETER SkipHarness
    Jika di-set, skip fase OBSERVE (gunakan manifest yang sudah ada).
    Berguna untuk re-analyze hasil run sebelumnya.

.PARAMETER OutputReport
    Path file laporan JSON output. Default: <ShotsDir>\run-analyze-report.json

.PARAMETER ReproducingScenario
    Path (relatif ke ProjectPath) ke scenario yang dirujuk fix-request.json sebagai
    reproducing_scenario. Jika diisi, file ini otomatis masuk daftar protected file --
    lihat GATE di bawah.

.PARAMETER ProtectedPatterns
    Daftar pola (wildcard, relatif ke ProjectPath, pakai "/" bukan "\") yang tidak boleh
    disentuh oleh patch yang sedang diverifikasi. Default mencakup seluruh scenarios/,
    file ignore-config visual-diff, dan tiga template runtime (ScenarioRunner/
    GameStateWriter/ErrorTracker.gd) yang di-vendor ke scripts/ project.
    Lihat GAME_STATE_SPEC.md bagian "fix-request.json" untuk konteks kenapa gate ini ada:
    fix loop tanpa manusia di antara "patch ditulis" dan "patch dijalankan" tidak punya
    kesempatan lain menangkap patch yang melemahkan alat ukurnya sendiri.

.PARAMETER GateBaseRef
    Git ref pembanding untuk deteksi file yang berubah. Default: "HEAD" (uncommitted
    working-tree changes, cocok untuk patch yang belum di-commit di worktree isolasi).

.EXAMPLE
    # Loop lengkap dengan smoke test
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" -ProjectPath "C:\dev\mygame"

.EXAMPLE
    # Jalankan scenario spesifik
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
        -ProjectPath "C:\dev\mygame" `
        -ScenarioName "save_load"

.EXAMPLE
    # Skip harness, hanya analyze hasil yang sudah ada
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
        -ProjectPath "C:\dev\mygame" `
        -SkipHarness

.EXAMPLE
    # Fix-loop mode: isolasi patch di worktree + verifikasi scope + gate
    & "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
        -ProjectPath "C:\dev\mygame" `
        -FixLoopMode `
        -FixRequestPath "C:\dev\mygame\shots\fix-requests.json" `
        -PatchBranch "fix/heal-bug-20260725" `
        -PatchRef "fix/heal-bug-20260725" `
        -GateBaseRef "main"
#>

[CmdletBinding()]
param(
    [string]   $ProjectPath          = "",
    [string]   $ScenarioName         = "",
    [string]   $GodotExe             = "",
    [int]      $Timeout              = 180,
    [switch]   $SkipHarness,
    [string]   $OutputReport         = "",
    [string]   $ReproducingScenario  = "",
    [string[]] $ProtectedPatterns    = @(),
    [string]   $GateBaseRef          = "HEAD",
    [string]   $PatchRef             = "",
    # Tahap 2: Fix-loop mode
    [switch]   $FixLoopMode,
    [string]   $FixRequestPath       = "",
    [string]   $PatchBranch          = "",
    [int]      $MaxIterations        = 2,
    [string]   $WorktreeBasePath     = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPs1 = Join-Path $PSScriptRoot "_common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    Write-Host "[run-analyze] FAIL _common.ps1 tidak ditemukan di $PSScriptRoot" -ForegroundColor Red
    Write-Host "[run-analyze]      Instalasi tidak lengkap. Jalankan setup.ps1 dari root repo framework." -ForegroundColor Red
    exit 1
}
. $commonPs1

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Phase { param($phase, $msg)
    Write-Host "[run-analyze] $phase  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg)
    Write-Host "[run-analyze] OK   $msg" -ForegroundColor Green }
function Write-Warn  { param($msg)
    Write-Host "[run-analyze] WARN $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg)
    Write-Host "[run-analyze] FAIL $msg" -ForegroundColor Red; exit 1 }
function Write-Info  { param($msg)
    Write-Host "[run-analyze]      $msg" -ForegroundColor Gray }

$kiloConfig = Join-Path $env:USERPROFILE ".config\kilo"
$harnessPs1 = Join-Path $kiloConfig "tools\shot-harness.ps1"

# -- TAHAP 2: Worktree provisioning -----------------------------------------------
# Setiap iterasi fix-loop berjalan di git worktree terpisah, bukan working tree utama.
# Ini memastikan:
#   - Patch AI tidak mengkontaminasi main/develop branch sampai lolos verifikasi
#   - Cleanup bersih: buang worktree = buang semua artefak patch yang gagal
#   - Dua iterasi paralel bisa berjalan tanpa konflik (worktree path unik)
#
# Kontrak: commit-before-verify
#   AI harus COMMIT patch ke branch di dalam worktree SEBELUM gate dievaluasi.
#   Gate menggunakan -PatchRef (nama branch) untuk diff, bukan working-tree diff.
#   Ini mencegah noise dari file runtime (.godot/, shots/) masuk ke evaluasi gate.
function Invoke-FixLoopWorktree {
    param(
        [string] $RepoPath,
        [string] $BranchName,
        [string] $BaseBranch   = "main",
        [string] $WorktreeBase = ""
    )

    $result = [ordered]@{
        success      = $false
        worktree_path = ""
        branch       = $BranchName
        error        = ""
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath ".git"))) {
        $result.error = "ProjectPath bukan git repository -- worktree tidak bisa dibuat"
        return $result
    }

    # Tentukan path worktree: default di parent project + nama branch (sanitized)
    if ($WorktreeBase -eq "") {
        $WorktreeBase = Split-Path $RepoPath -Parent
    }
    $safeBranch    = $BranchName -replace '[\\/:*?"<>|]', '-'
    $worktreePath  = Join-Path $WorktreeBase "_worktree_$safeBranch"

    # Cleanup sisa worktree dari run sebelumnya jika ada
    if (Test-Path -LiteralPath $worktreePath) {
        Push-Location $RepoPath
        try {
            git worktree remove --force $worktreePath 2>$null | Out-Null
        } catch { }
        Pop-Location
        if (Test-Path -LiteralPath $worktreePath) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Push-Location $RepoPath
    try {
        # Buat branch baru dari BaseBranch (atau dari HEAD jika BaseBranch tidak ada)
        # CATATAN: git branch --list mengembalikan $null (bukan string kosong) untuk branch
        # yang belum ada -- jangan panggil .Trim() langsung, bungkus dalam @() dulu.
        $branchListOutput = @(git branch --list $BranchName 2>$null | Where-Object { $_ -ne $null })
        $branchExists = $branchListOutput.Count -gt 0
        if (-not $branchExists) {
            $baseListOutput = @(git branch --list $BaseBranch 2>$null | Where-Object { $_ -ne $null })
            $baseExists = $baseListOutput.Count -gt 0
            $startPoint = if ($baseExists) { $BaseBranch } else { "HEAD" }
            git branch $BranchName $startPoint 2>$null | Out-Null
        }

        # Buat worktree yang checkout branch tersebut
        # git worktree add menulis "Preparing worktree..." ke stderr meski sukses.
        # Dengan $ErrorActionPreference = Stop, output stderr native command bisa
        # memicu terminating error. Simpan dan restore EAP untuk panggilan ini saja.
        #
        # PENTING: git tidak bisa checkout branch yang sudah aktif di working tree lain.
        # Jika branch sedang aktif (current HEAD), gunakan commit hash (detached) sebagai workaround.
        $currentBranch = @(git branch --show-current 2>$null) | Select-Object -First 1
        $useRef = $BranchName
        if ($currentBranch -eq $BranchName) {
            # Branch sedang aktif di working tree utama -- checkout via commit hash (detached)
            $commitHash = @(git rev-parse $BranchName 2>$null) | Select-Object -First 1
            if ($commitHash -ne "") {
                $useRef = $commitHash
                Write-Phase "WORKTREE" "Branch aktif di working tree -- checkout via commit hash: $commitHash"
            }
        }
        $savedEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            git worktree add $worktreePath $useRef 2>$null | Out-Null
        } finally {
            $ErrorActionPreference = $savedEAP
        }

        if (Test-Path -LiteralPath $worktreePath) {
            $result.success       = $true
            $result.worktree_path = $worktreePath
            Write-Phase "WORKTREE" "Provisioned: $worktreePath (branch: $BranchName)"
        } else {
            $result.error = "git worktree add tidak menghasilkan folder: $worktreePath"
        }
    } catch {
        $result.error = "Gagal membuat worktree: $_"
    } finally {
        Pop-Location
    }

    return $result
}

function Remove-FixLoopWorktree {
    param(
        [string] $RepoPath,
        [string] $WorktreePath,
        [string] $BranchName,
        [switch] $DeleteBranch
    )
    if (-not (Test-Path -LiteralPath $WorktreePath)) { return }
    Push-Location $RepoPath
    try {
        git worktree remove --force $WorktreePath 2>$null | Out-Null
    } catch { } finally { Pop-Location }
    if (Test-Path -LiteralPath $WorktreePath) {
        Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($DeleteBranch -and $BranchName -ne "") {
        Push-Location $RepoPath
        try { git branch -D $BranchName 2>$null | Out-Null } catch { } finally { Pop-Location }
    }
    # Verifikasi aktual -- jangan laporkan "Removed" jika direktori masih ada
    if (Test-Path -LiteralPath $WorktreePath) {
        Write-Warn "WORKTREE cleanup gagal -- direktori masih ada: $WorktreePath"
        Write-Warn "Kemungkinan ada proses yang masih memegang direktori. Kill proses Godot/Unity yang masih berjalan."
    } else {
        Write-Phase "WORKTREE" "Removed: $WorktreePath"
    }
}

# -- TAHAP 3: Scope constraint (allowlist dari fix-request) -----------------------
# AI hanya boleh mengubah file yang tercantum di target_file dalam fix-request.json.
# Ini membatasi blast radius tanpa membatasi kemampuan AI menulis kode.
#
# PENTING: Denylist (Tahap 4 / Test-ProtectedFileViolation) SELALU dievaluasi lebih dulu
# dan MENANG atas allowlist. Artinya: meskipun fix-request menyebut file verifikasi
# sebagai target_file, gate Tahap 4 tetap menolaknya. fix-request tidak bisa dipakai
# sebagai celah melewati proteksi yang sudah ada.
function Test-ScopeViolation {
    param(
        [string]   $RepoPath,
        [string]   $FixRequestPath,
        [string]   $BaseRef  = "HEAD",
        [string]   $PatchRef = ""
    )

    $result = [ordered]@{
        violated        = $false
        changed_files   = @()
        out_of_scope    = @()
        allowed_files   = @()
        fix_request_id  = ""
        error           = ""
    }

    # Baca fix-request.json
    if (-not (Test-Path -LiteralPath $FixRequestPath)) {
        $result.error = "fix-request tidak ditemukan: $FixRequestPath"
        return $result
    }
    try {
        $fixReqData = Get-Content -LiteralPath $FixRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $result.error = "fix-request.json tidak bisa di-parse: $_"
        return $result
    }

    # Kumpulkan semua target_file dari semua fix_requests
    # (satu file fix-request bisa berisi beberapa fix_request untuk satu iterasi)
    $allowedFiles = [System.Collections.Generic.List[string]]::new()
    $frIds        = [System.Collections.Generic.List[string]]::new()
    $requests     = if ($fixReqData.PSObject.Properties["fix_requests"]) { @($fixReqData.fix_requests) } `
                    elseif ($fixReqData.PSObject.Properties["fix_request_id"]) { @($fixReqData) } `
                    else { @() }
    foreach ($req in $requests) {
        if ($req.PSObject.Properties["fix_request_id"]) { $frIds.Add($req.fix_request_id) }
        if ($req.PSObject.Properties["target_file"] -and $req.target_file -ne "") {
            $tf = $req.target_file -replace '\\', '/'
            if (-not $allowedFiles.Contains($tf)) { $allowedFiles.Add($tf) }
        }
    }
    $result.allowed_files  = @($allowedFiles)
    $result.fix_request_id = $frIds -join ", "

    if ($allowedFiles.Count -eq 0) {
        # Tidak ada target_file -- scope tidak bisa dievaluasi, tidak memblokir
        $result.error = "fix-request tidak punya target_file -- scope check dilewati"
        return $result
    }

    # Dapatkan daftar file yang berubah (same logic as Test-ProtectedFileViolation)
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath ".git"))) {
        $result.error = "bukan git repo -- scope check tidak bisa dievaluasi"
        return $result
    }
    Push-Location $RepoPath
    # EAP save/restore: sama seperti Test-ProtectedFileViolation -- git advisory
    # warnings crash dengan ErrorActionPreference = Stop di PS 5.1.
    $savedEAPScope = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($PatchRef -ne "") {
            $changed = @(git diff --name-only $BaseRef $PatchRef 2>$null |
                         Where-Object { $_ -ne "" } | Select-Object -Unique)
        } else {
            $unstaged = @(git diff --name-only $BaseRef 2>$null)
            $staged   = @(git diff --name-only --cached $BaseRef 2>$null)
            $changed  = @($unstaged + $staged | Where-Object { $_ -ne "" } | Select-Object -Unique)
        }
    } finally {
        $ErrorActionPreference = $savedEAPScope
        Pop-Location
    }

    $result.changed_files = @($changed | ForEach-Object { $_ -replace '\\', '/' })

    # Cek apakah ada file yang berubah tapi tidak ada di allowlist
    $outOfScope = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $result.changed_files) {
        $inScope = $false
        foreach ($allowed in $allowedFiles) {
            # Exact match atau prefix match (kalau allowed adalah direktori)
            if ($f -eq $allowed -or $f.StartsWith("$allowed/") -or ($allowed -like "*") -and ($f -like $allowed)) {
                $inScope = $true; break
            }
        }
        if (-not $inScope) { $outOfScope.Add($f) }
    }

    $result.out_of_scope = @($outOfScope)
    $result.violated     = ($outOfScope.Count -gt 0)
    return $result
}

# -- GATE: protected-file hard block -----------------------------------------------
# Tanpa manusia di antara "patch ditulis" dan "patch dijalankan" (fix loop otonom),
# gate ini adalah SATU-SATUNYA kesempatan menangkap patch yang melemahkan alat ukur
# verifikasinya sendiri -- scenario yang diedit supaya lolos, ignore-region yang
# diperluas supaya regresi visual tidak terdeteksi, atau template runtime yang
# diubah supaya assertion tidak lagi menguji apa yang seharusnya. Ini keputusan
# pass/fail itu sendiri, bukan filter tambahan di laporan -- kalau ada match,
# verifikasi GAGAL tanpa terkecuali, terlepas dari bersihnya hasil scenario/visual-diff.
function Test-ProtectedFileViolation {
    param(
        [string]   $RepoPath,
        [string[]] $ProtectedPatterns,
        [string]   $BaseRef  = "HEAD",
        [string]   $PatchRef = ""
    )
    $result = [ordered]@{
        violated       = $false
        changed_files  = @()
        protected_hits = @()
    }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath ".git"))) {
        # Bukan git repo -- gate tidak bisa dievaluasi. Fail-closed (anggap violated),
        # bukan fail-open, karena tanpa git tidak ada cara lain memverifikasi scope patch.
        $result.violated = $true
        $result.protected_hits = @("(bukan git repository -- gate tidak bisa dievaluasi, fail-closed)")
        return $result
    }
    Push-Location $RepoPath
    # EAP save/restore: git advisory warnings (LF/CRLF, autocrlf) diteruskan sebagai
    # error stream di PS 5.1 dan bisa crash dengan $ErrorActionPreference = "Stop".
    # 2>$null tidak menangkap ini -- harus turunkan EAP sementara saat panggil git.
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($PatchRef -ne "") {
            # Two-ref diff: bandingkan dua commit, tidak termasuk perubahan working-tree.
            $changed = @(git diff --name-only $BaseRef $PatchRef 2>$null |
                         Where-Object { $_ -ne "" } | Select-Object -Unique)
        } else {
            # Single-ref diff (backward-compatible): bandingkan working-tree vs ref.
            $unstaged = @(git diff --name-only $BaseRef 2>$null)
            $staged   = @(git diff --name-only --cached $BaseRef 2>$null)
            $changed  = @($unstaged + $staged | Where-Object { $_ -ne "" } | Select-Object -Unique)
        }
    } finally {
        $ErrorActionPreference = $savedEAP
        Pop-Location
    }
    $result.changed_files = $changed
    foreach ($file in $changed) {
        $fileNorm = $file -replace '\\', '/'
        foreach ($pattern in $ProtectedPatterns) {
            if ($fileNorm -like $pattern) {
                $result.protected_hits += "$fileNorm (cocok pola: $pattern)"
                $result.violated = $true
            }
        }
    }
    return $result
}

# Default protected patterns -- mulai ketat, longgarkan lewat -ProtectedPatterns
# eksplisit per kasus, bukan sebaliknya (lihat GAME_STATE_SPEC.md).
function Get-DefaultProtectedPatterns {
    param([string] $ReproducingScenario = "")
    $patterns = [System.Collections.Generic.List[string]]::new()
    if ($ReproducingScenario -ne "") {
        $patterns.Add(($ReproducingScenario -replace '\\', '/'))
    }
    $patterns.Add("scenarios/*")
    $patterns.Add("scenarios/*/*")
    $patterns.Add("shots.zoom.json")
    $patterns.Add("visual-diff-ignore.json")
    # Pola layout-agnostic: cocok dengan nama file saja, bukan path direktori spesifik.
    # Ini penting karena game berbeda memakai direktori berbeda:
    #   bread-adventure: src/global/ScenarioRunner.gd
    #   godot-tiny-mmo:  source/common/framework/ScenarioRunner.gd
    #   godot-open-rts:  source/scripts/ScenarioRunner.gd  (hanya ini yang cocok dengan pola lama)
    # PowerShell -like dengan "*ScenarioRunner.gd" cocok dengan path apa pun yang berakhiran nama file itu,
    # termasuk path tanpa komponen direktori (file di root project).
    #
    # Catatan: pola ini secara intentional broad — ia cocok dengan file bernamakan sama di direktori
    # manapun (termasuk addons/ atau vendor/ pihak ketiga). Ini adalah trade-off yang disengaja:
    # false-positive lebih aman daripada false-negative (AI memodifikasi verifier-nya sendiri tanpa
    # terdeteksi). Jika false-positive terjadi pada file pihak ketiga, override lewat -ProtectedPatterns
    # di pemanggil (tambahkan pola yang lebih spesifik untuk mengecualikan path tertentu).
    $patterns.Add("*ScenarioRunner.gd")
    $patterns.Add("*GameStateWriter.gd")
    $patterns.Add("*ErrorTracker.gd")
    return @($patterns)
}

# -- Auto-migrate manifest jika schema lama ----------------------------------------
function Invoke-SchemaMigrationIfNeeded {
    param([string]$manifestPath)
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sv = if ($m.PSObject.Properties["schema_version"]) { $m.schema_version } else { "1.0" }
        if ($sv -ne "1.1") {
            $migScript = Join-Path $kiloConfig "tools\schema-migration.ps1"
            if (Test-Path -LiteralPath $migScript) {
                Write-Warn "Manifest schema $sv terdeteksi -- migrasi ke 1.1..."
                & $migScript -ManifestPath $manifestPath -Backup:$true
                Write-Ok "Manifest dimigrasikan ke schema 1.1"
            }
        }
    } catch { }
}
# ── 1. Resolve ProjectPath ─────────────────────────────────────────────────────
if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Write-Fail "ProjectPath tidak ditemukan: $ProjectPath"
}

# ── 1a. Resolve Godot executable (perlu sebelum worktree --import) ─────────────
if ($GodotExe -eq "") {
    $GodotExe = Resolve-GodotExecutable
    if ($GodotExe -eq "") {
        Write-Warn "Godot executable tidak ditemukan — fase RUN dan worktree --import akan di-skip"
        Write-Warn "Gunakan -GodotExe untuk specify path, atau pastikan godot ada di PATH"
    }
}

# ── 1b. TAHAP 2: Provision worktree jika -FixLoopMode aktif ─────────────────
# Worktree di-provision SEBELUM harness dijalankan sehingga semua operasi
# (OBSERVE, RUN, ANALYZE, GATE) terjadi di dalam isolasi yang benar.
$worktreeInfo = $null
$worktreeProjectPath = $ProjectPath  # default: gunakan ProjectPath langsung

if ($FixLoopMode -and $PatchBranch -ne "") {
    Write-Phase "WORKTREE" "Provisioning worktree untuk branch '$PatchBranch'..."
    $worktreeInfo = Invoke-FixLoopWorktree `
        -RepoPath $ProjectPath `
        -BranchName $PatchBranch `
        -BaseBranch $GateBaseRef `
        -WorktreeBase $WorktreeBasePath

    if ($worktreeInfo.success) {
        Write-Ok "Worktree: $($worktreeInfo.worktree_path)"
        # Jalankan harness dan analisis di dalam worktree (bukan ProjectPath asli)
        # supaya perubahan AI yang belum di-commit tidak bocor ke working tree utama.
        $worktreeProjectPath = $worktreeInfo.worktree_path

        # Jalankan --import agar .godot/ terisi di worktree sebelum scenario dijalankan.
        # Tanpa ini Godot tidak bisa compile script dan scenario selalu gagal di step 1.
        # Guard: hanya jalankan jika project.godot ada di worktree -- tanpanya Godot
        # menampilkan dialog "no main scene" dan tidak pernah exit, menyebabkan proses yatim
        # yang menahan direktori worktree sehingga cleanup selalu gagal.
        $worktreeGodot = Join-Path $worktreeProjectPath "project.godot"
        if ($GodotExe -ne "" -and (Test-Path -LiteralPath $worktreeGodot)) {
            # Tahap 1: Seed .godot/imported/ dari ProjectPath asli jika ada.
            # git worktree hanya meng-checkout file yang di-track -- .godot/imported/ tidak
            # di-track karena binary assets besar, sehingga worktree baru selalu kosong.
            # Copy asset cache dari ProjectPath memungkinkan Godot compile script tanpa
            # harus re-import seluruh project dari nol (yang butuh akses ke asset binary asli).
            $srcImported  = Join-Path $ProjectPath ".godot\imported"
            $dstGodotDir  = Join-Path $worktreeProjectPath ".godot"
            $dstImported  = Join-Path $dstGodotDir "imported"
            if ((Test-Path -LiteralPath $srcImported) -and -not (Test-Path -LiteralPath $dstImported)) {
                Write-Phase "WORKTREE" "Menyalin .godot/imported/ dari ProjectPath ke worktree..."
                try {
                    if (-not (Test-Path -LiteralPath $dstGodotDir)) {
                        New-Item -ItemType Directory -Path $dstGodotDir | Out-Null
                    }
                    Copy-Item -LiteralPath $srcImported -Destination $dstImported -Recurse -Force
                    $copiedCount = @(Get-ChildItem -LiteralPath $dstImported -Recurse -File).Count
                    Write-Ok "Salin .godot/imported/ selesai ($copiedCount file)"
                } catch {
                    Write-Warn "Gagal menyalin .godot/imported/: $_ -- lanjutkan dengan --import"
                }
            }

            # Tahap 2: Jalankan --import untuk mensync perubahan script dari patch.
            # Ini tetap diperlukan karena patch mungkin mengubah script GDScript yang
            # cache-nya di .godot/imported/ perlu diperbarui.
            Write-Phase "WORKTREE" "Menjalankan --import di worktree (isi .godot/)..."
            # --headless WAJIB: worktree yang baru dibuat sering belum punya aset biner
            # (tidak dilacak git), sehingga import gagal dan Godot berjendela memunculkan
            # dialog modal yang menahan proses sampai timeout. Fix-loop harus bisa berjalan
            # tanpa pengawasan; satu dialog modal cukup untuk menggantungkannya.
            $importProc = Start-Process -FilePath $GodotExe `
                -ArgumentList "--path", "`"$worktreeProjectPath`"", "--headless", "--import", "--quit-after", "2" `
                -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($importProc) {
                $importProc.Handle | Out-Null
                $importFinished = $importProc.WaitForExit(60000)
                if (-not $importFinished) {
                    $null = Stop-ProcessTree -Process $importProc
                    Write-Warn "Import worktree timeout (60 detik) -- proses Godot dibunuh, lanjutkan tanpa .godot/"
                } else {
                    Write-Ok "Import worktree selesai (exit: $($importProc.ExitCode))"
                }
            }
        } elseif ($GodotExe -eq "") {
            Write-Warn "GodotExe belum diketahui saat provisioning -- --import di-skip"
        } else {
            Write-Warn "project.godot tidak ditemukan di worktree -- --import di-skip (bukan project Godot)"
        }
    } else {
        Write-Warn "Worktree gagal di-provision: $($worktreeInfo.error)"
        Write-Warn "Melanjutkan tanpa isolasi worktree (fallback ke ProjectPath)"
    }
} elseif ($FixLoopMode -and $PatchBranch -eq "") {
    Write-Warn "-FixLoopMode aktif tapi -PatchBranch tidak diisi -- worktree tidak dibuat"
}

# ── 1c. Turunkan -PatchRef otomatis dari -PatchBranch saat fix-loop ──────────
# Kontrak "commit-before-verify": di fix-loop otonom patch sudah di-commit ke
# $PatchBranch, jadi gate HARUS membandingkan commit-vs-commit ($GateBaseRef vs
# $PatchBranch). Diff dua-ref itu kebal terhadap noise working-tree (.godot/,
# shots/) yang dihasilkan harness saat verifikasi berjalan.
#
# Sebelumnya $PatchRef adalah parameter terpisah yang tidak diturunkan dari
# apa pun -- pemanggil fix-loop harus mengingatnya sendiri, dan kalau lupa
# gate diam-diam jatuh ke diff working-tree. Kontraknya terdokumentasi tapi
# tidak ditegakkan.
#
# Kalau branch-nya tidak ada, JANGAN set $PatchRef: `git diff base branch-hantu`
# mengembalikan kosong, dan gate akan lolos tanpa memeriksa apa pun (fail-open).
# Fallback ke diff single-ref lebih konservatif -- mungkin ada false-positive
# dari file runtime, tapi tidak pernah meloloskan patch tanpa diperiksa.
if ($FixLoopMode -and $PatchBranch -ne "" -and $PatchRef -eq "") {
    $savedEAPRef = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Push-Location $ProjectPath
    try {
        git rev-parse --verify --quiet "$PatchBranch^{commit}" 2>$null | Out-Null
        $branchResolves = ($LASTEXITCODE -eq 0)
    } catch {
        $branchResolves = $false
    } finally {
        Pop-Location
        $ErrorActionPreference = $savedEAPRef
    }

    if ($branchResolves) {
        $PatchRef = $PatchBranch
        Write-Info "Gate mode: two-ref diff ($GateBaseRef..$PatchBranch)"
    } else {
        Write-Warn "Branch '$PatchBranch' tidak resolve -- gate fallback ke diff single-ref (working-tree)"
    }
}

$projectName = Split-Path $worktreeProjectPath -Leaf
Write-Phase "INIT" "Project: $projectName ($worktreeProjectPath)"

# ── 2. Resolve ShotsDir dari konfigurasi harness ──────────────────────────────
# Baca project.godot untuk mapping user:// -> AppData path
# Mendukung config/use_custom_user_dir=true + config/custom_user_dir_name seperti shot-harness.ps1
$shotsDir = ""
$projectGodot = Join-Path $worktreeProjectPath "project.godot"
if (Test-Path -LiteralPath $projectGodot) {
    try {
        $content = Get-Content -LiteralPath $projectGodot -Raw -Encoding UTF8
        if ($content -match 'config/name="([^"]+)"') {
            $appName = $Matches[1]
            # Cek apakah project menggunakan custom user dir
            $useCustomDir  = $content -match 'config/use_custom_user_dir=true'
            $customDirName = ""
            if ($useCustomDir -and $content -match 'config/custom_user_dir_name="([^"]+)"') {
                $customDirName = $Matches[1]
            }
            if ($useCustomDir -and $customDirName -ne "") {
                # Custom user dir: %APPDATA%\<custom_dir_name>\shots
                $safeName = $customDirName -replace '[\\/:*?"<>|]', '_'
                $candidates = @("$env:APPDATA\$safeName\shots")
            } else {
                # Standar Godot: %APPDATA%\Godot\app_userdata\<nama_project>\shots
                $safeName = $appName -replace '[\\/:*?"<>|]', '_'
                $candidates = @(
                    "$env:APPDATA\Godot\app_userdata\$safeName\shots",
                    "$env:APPDATA\godot\app_userdata\$safeName\shots"
                )
            }
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c) { $shotsDir = $c; break }
            }
            # Jika belum ada, gunakan kandidat pertama
            if ($shotsDir -eq "") {
                $shotsDir = $candidates[0]
            }
        }
    } catch { }
}
if ($shotsDir -eq "") {
    $shotsDir = Join-Path $worktreeProjectPath "shots"
}
Write-Info "ShotsDir: $shotsDir"

if ($OutputReport -eq "") {
    $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $OutputReport = Join-Path $shotsDir "run-analyze-report_$ts.json"
}

# ── FASE 1: OBSERVE ────────────────────────────────────────────────────────────
$manifestPath = Join-Path $shotsDir "shots-manifest.json"
$manifest     = $null
$phase1Status = "skip"

if (-not $SkipHarness) {
    Write-Phase "OBSERVE" "Menjalankan shot harness..."

    if (-not (Test-Path -LiteralPath $harnessPs1)) {
        Write-Fail "shot-harness.ps1 tidak ditemukan: $harnessPs1"
    }

    # Panggil langsung tanpa array-splat agar argumen terikat by-name, bukan posisional
    $harnessCallArgs = @{
        ProjectPath = $worktreeProjectPath
        Timeout     = $Timeout
    }
    if ($GodotExe -ne "") { $harnessCallArgs["GodotExe"] = $GodotExe }

    # 'exit 1' di script yang dipanggil dengan & tidak melempar exception, jadi catch
    # tidak pernah aktif. Tanpa cek exit code, harness yang GAGAL tetap tercatat
    # phase1Status = "ok" dan ikut ke laporan JSON sebagai sukses.
    $harnessExit = 0
    try {
        $global:LASTEXITCODE = 0
        & $harnessPs1 @harnessCallArgs
        $harnessExit = $LASTEXITCODE
    } catch {
        Write-Warn "Harness error: $_"
        $harnessExit = 1
    }
    if ($harnessExit -eq 0) {
        $phase1Status = "ok"
        Write-Ok "Harness selesai"
    } else {
        Write-Warn "Harness gagal (exit $harnessExit) — lanjut dengan manifest yang ada"
        $phase1Status = "warn"
    }
} else {
    Write-Phase "OBSERVE" "SkipHarness — menggunakan manifest yang sudah ada"
    $phase1Status = "skipped"
}

# Baca manifest
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $telemetryPhase = $manifest.telemetry_phase
        $pngCount       = $manifest.png_count
        Write-Ok "Manifest: $pngCount PNG, fase=$telemetryPhase"
    } catch {
        Write-Warn "Gagal membaca manifest: $_"
    }
} else {
    Write-Warn "Manifest tidak ditemukan: $manifestPath"
}

# ── FASE 2: GENERATE / RESOLVE SCENARIO ────────────────────────────────────────
Write-Phase "GENERATE" "Resolving scenario..."

$scenarioPath = ""
$scenariosDir = Join-Path $worktreeProjectPath "scenarios"
$phase2Status = "ok"

if ($ScenarioName -ne "") {
    # Cari scenario yang diminta
    $candidates = @(
        (Join-Path $scenariosDir "$ScenarioName.json"),
        (Join-Path $scenariosDir $ScenarioName),
        $ScenarioName
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $scenarioPath = $c; break }
    }
    if ($scenarioPath -eq "") {
        Write-Warn "Scenario '$ScenarioName' tidak ditemukan, fallback ke smoke test"
        $phase2Status = "fallback"
    } else {
        Write-Ok "Scenario: $scenarioPath"
    }
}

if ($scenarioPath -eq "") {
    # Fallback: gunakan smoke.json dari project atau template global
    $fallbackCandidates = @(
        (Join-Path $scenariosDir "smoke.json"),
        (Join-Path $kiloConfig "scenarios-templates\smoke.json")
    )
    foreach ($c in $fallbackCandidates) {
        if (Test-Path -LiteralPath $c) { $scenarioPath = $c; break }
    }

    if ($scenarioPath -eq "") {
        Write-Warn "Tidak ada scenario tersedia. Buat smoke scenario minimal..."
        # Buat smoke scenario minimal inline
        if (-not (Test-Path -LiteralPath $scenariosDir)) {
            New-Item -ItemType Directory -Path $scenariosDir | Out-Null
        }
        $minimalSmoke = @{
            scenario_id = "auto_smoke"
            description = "Auto-generated minimal smoke test"
            version = "1.0"
            tags = @("auto-generated", "smoke", "minimal")
            steps = @(
                @{ type = "log"; message = "=== AUTO SMOKE TEST ===" },
                @{ type = "wait_frames"; frames = 60 },
                @{ type = "screenshot"; name = "auto_smoke_01_launch" },
                @{ type = "write_state" },
                @{ type = "log"; message = "=== AUTO SMOKE TEST SELESAI ===" }
            )
        }
        $scenarioPath = Join-Path $scenariosDir "auto_smoke.json"
        $minimalSmoke | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scenarioPath -Encoding UTF8
        Write-Ok "Smoke scenario minimal dibuat: $scenarioPath"
        $phase2Status = "generated"
    } else {
        Write-Ok "Fallback scenario: $scenarioPath"
        $phase2Status = "fallback"
    }
}

# Salin scenario ke ShotsDir sebagai test_scenario.json
if (-not (Test-Path -LiteralPath $shotsDir)) {
    New-Item -ItemType Directory -Path $shotsDir | Out-Null
}
$testScenarioPath = Join-Path $shotsDir "test_scenario.json"
Copy-Item -LiteralPath $scenarioPath -Destination $testScenarioPath -Force
Write-Info "Scenario disalin ke: $testScenarioPath"

# ── FASE 3: RUN ────────────────────────────────────────────────────────────────
Write-Phase "RUN" "Menjalankan scenario..."

$scenarioResultPath = Join-Path $shotsDir "scenario_result.json"
$scenarioResult     = $null
$phase3Status       = if ($GodotExe -eq "") { "skip_no_godot" } else { "skip" }

if ($GodotExe -eq "") {
    Write-Warn "Godot executable tidak ditemukan — skip fase RUN"
    Write-Warn "Gunakan -GodotExe untuk specify path, atau pastikan godot ada di PATH"
}

if ($phase3Status -ne "skip_no_godot" -and (Test-Path -LiteralPath $projectGodot)) {
    $ts_run = Get-Date
    $scenarioLog = "$env:TEMP\kilo_scenario_stderr_$(Get-Date -Format 'yyyyMMddHHmmss').txt"
    try {
        $scenarioFlag = "user://shots/test_scenario.json"
        # --log-file menyatukan stdout dan stderr dalam SATU berkas berurutan. Itu yang
        # membuat diagnostik engine bisa dikembalikan ke langkah yang menghasilkannya:
        # -RedirectStandardError saja memisahkan kedua aliran, dan begitu terpisah tidak ada
        # lagi cara mengetahui error itu terjadi saat langkah keberapa.
        $proc = Start-Process -FilePath $GodotExe `
            -ArgumentList "--path", "`"$worktreeProjectPath`"", "--log-file", "`"$scenarioLog`"", "--", "--scenario", $scenarioFlag `
            -PassThru -NoNewWindow
        $proc.Handle | Out-Null
        $finished = $proc.WaitForExit($Timeout * 1000)
        if (-not $finished) {
            if (-not (Stop-ProcessTree -Process $proc)) {
                Write-Warn "Proses Godot tidak mau berhenti setelah dibunuh -- berkasnya mungkin masih terkunci"
            }
            Write-Warn "Timeout ($($Timeout) detik) saat menjalankan scenario"
            $phase3Status = "timeout"
        } else {
            $phase3Status = "ok"
            $elapsed = [math]::Round(((Get-Date) - $ts_run).TotalSeconds, 1)
            Write-Ok "Scenario selesai dalam $elapsed detik"
        }
    } catch {
        Write-Warn "Gagal menjalankan scenario: $_"
        $phase3Status = "error"
    }

    # Deteksi compile/load error dari stderr Godot -- error ini tidak muncul di scenario_result.json
    # karena ScenarioRunner tidak berjalan sama sekali jika script game gagal di-compile,
    # atau berjalan tapi game gagal load resource sehingga state tidak valid.
    # Wording bervariasi per Godot versi dan konteks -- cakup keduanya:
    #   - GDScript compile: "Compile Error", "Failed to load script", "SCRIPT ERROR:.*Parse Error"
    #   - Resource loader: "Cannot open file", "Failed loading resource",
    #     "ERROR:.*Parse Error.*non-existent resource"
    # Kecualikan GDScript::reload (hot-reload artifact, bukan genuine error) dan
    # baris yang hanya berisi "ERROR: " tanpa konten (false positive dari Godot editor noise).
    if (Test-Path -LiteralPath $scenarioLog) {
        try {
            $scenarioLogLines = @(Get-Content $scenarioLog -Encoding UTF8 -ErrorAction SilentlyContinue)
            $compileErrors = @($scenarioLogLines | Where-Object {
                $_ -match "Compile Error|Failed to load script|SCRIPT ERROR.*Parse Error" `
                    -or ($_ -match "Cannot open file 'res://|Failed loading resource|ERROR:.*Parse Error.*non-existent resource" `
                         -and $_ -notmatch "user://")
            } | Where-Object {
                $_ -notmatch "GDScript::reload"
            })
            if ($compileErrors.Count -gt 0 -and $phase3Status -eq "ok") {
                Write-Warn "Terdeteksi $($compileErrors.Count) compile/load error di stderr Godot"
                foreach ($ce in $compileErrors | Select-Object -First 3) {
                    Write-Warn "  $ce"
                }
                $phase3Status = "compile_error"
            }
        } catch { }
    }

} elseif ($phase3Status -ne "skip_no_godot") {
    Write-Warn "project.godot tidak ditemukan — skip fase RUN"
    $phase3Status = "skip_no_project"
}

# Baca hasil scenario — hanya jika file ditulis SETELAH run dimulai (guard stale result)
if (Test-Path -LiteralPath $scenarioResultPath) {
    $resultMtime = (Get-Item -LiteralPath $scenarioResultPath).LastWriteTime
    if ($phase3Status -in @("ok", "timeout") -and $resultMtime -lt $ts_run) {
        Write-Warn "scenario_result.json tidak diperbarui setelah run (mtime: $resultMtime < ts_run: $ts_run) — hasil lama diabaikan"
        $phase3Status = "stale_result"
    }
    if ($phase3Status -ne "stale_result") {
        # Penempelan diagnostik HARUS setelah gerbang stale di atas. Menempel lebih dulu
        # berarti menulis ulang scenario_result.json, mtime-nya jadi baru, dan gerbang itu
        # tidak akan pernah bisa menyala lagi -- hasil lama dari run sebelumnya akan lolos
        # sebagai hasil run ini. Versi pertama perubahan ini melakukannya, dan TEST 13
        # menangkapnya.
        if ($scenarioLog -ne "" -and (Test-Path -LiteralPath $scenarioLog)) {
            try {
                if (-not (Add-GodotLogToScenarioResult -LogPath $scenarioLog -ResultPath $scenarioResultPath)) {
                    Write-Warn "log Godot tidak bisa ditempelkan — laporan ini tidak melihat error engine"
                }
            } catch {
                Write-Warn "Gagal menempelkan log Godot: $_"
            }
        }
        try {
            $scenarioResult = Get-Content -LiteralPath $scenarioResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Suport kedua kontrak field: steps_pass/steps_fail/steps_skip (ScenarioRunner v1)
            # dan passed/failed/skipped (format lama)
            $passed  = if ($scenarioResult.PSObject.Properties["steps_pass"])  { $scenarioResult.steps_pass }  `
                       elseif ($scenarioResult.PSObject.Properties["passed"])  { $scenarioResult.passed }  else { 0 }
            $failed  = if ($scenarioResult.PSObject.Properties["steps_fail"])  { $scenarioResult.steps_fail }  `
                       elseif ($scenarioResult.PSObject.Properties["failed"])  { $scenarioResult.failed }  else { 0 }
            $skipped = if ($scenarioResult.PSObject.Properties["steps_skip"])  { $scenarioResult.steps_skip }  `
                       elseif ($scenarioResult.PSObject.Properties["skipped"]) { $scenarioResult.skipped } else { 0 }
            $status  = $scenarioResult.status
            Write-Ok "Hasil: $status ($passed pass / $failed fail / $skipped skip)"
        } catch {
            Write-Warn "Gagal membaca scenario_result.json: $_"
        }
    }
}

# ── FASE 4: ANALYZE ────────────────────────────────────────────────────────────
Write-Phase "ANALYZE" "Menganalisis hasil..."

$analysis = @{
    visual_regression = $null
    scenario_findings = @()
    recommendations   = @()
    critical_issues   = @()
}

# 4a: Cek visual regression jika ada baseline
$diffReportPath = Join-Path $shotsDir "diff\diff-report.json"
$diffReport     = $null
$phase4aStatus  = "no_baseline"

if (Test-Path -LiteralPath $diffReportPath) {
    try {
        $diffReport = Get-Content -LiteralPath $diffReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $regressions = @($diffReport.files | Where-Object { $_.status -eq "REGRESI" })
        $newFiles    = @($diffReport.files | Where-Object { $_.status -eq "FILE_BARU" })
        $missing     = @($diffReport.files | Where-Object { $_.status -eq "HILANG" })

        $analysis.visual_regression = @{
            ok_count        = @($diffReport.files | Where-Object { $_.status -eq "OK" }).Count
            regression_count = $regressions.Count
            new_count       = $newFiles.Count
            missing_count   = $missing.Count
            regressions     = @($regressions | ForEach-Object { $_.file })
        }

        if ($regressions.Count -gt 0) {
            $analysis.critical_issues += "Visual regression: $($regressions.Count) file berubah"
            foreach ($r in $regressions) {
                $analysis.recommendations += "Review visual: $($r.file) ($($r.change_pct)% berubah)"
            }
        }
        $phase4aStatus = "ok"
        Write-Ok "Visual diff: $($regressions.Count) regresi, $($newFiles.Count) baru, $($missing.Count) hilang"
    } catch {
        Write-Warn "Gagal membaca diff-report: $_"
        $phase4aStatus = "error"
    }
} else {
    Write-Info "Tidak ada baseline — skip visual regression check"
    $analysis.recommendations += "Jalankan /baseline set untuk menyimpan baseline visual pertama"
}

# 4b: Analyze scenario results
if ($scenarioResult -ne $null) {
    # Suport kedua nama field: steps_fail/steps_pass/steps_skip/step_results (ScenarioRunner baru)
    # dan failed/passed/skipped/steps (format lama)
    $srFailed  = if ($scenarioResult.PSObject.Properties["steps_fail"])  { $scenarioResult.steps_fail }  `
                 elseif ($scenarioResult.PSObject.Properties["failed"])  { $scenarioResult.failed }  else { 0 }
    $srSkipped = if ($scenarioResult.PSObject.Properties["steps_skip"])  { $scenarioResult.steps_skip }  `
                 elseif ($scenarioResult.PSObject.Properties["skipped"]) { $scenarioResult.skipped } else { 0 }
    $srStepsField = if ($scenarioResult.PSObject.Properties["step_results"]) { "step_results" } else { "steps" }

    if ($srFailed -gt 0) {
        $failedSteps = @($scenarioResult.$srStepsField | Where-Object { $_.status -eq "fail" })
        foreach ($s in $failedSteps) {
            $sId   = if ($s.PSObject.Properties["step"])   { $s.step }   elseif ($s.PSObject.Properties["id"])   { $s.id }   else { "?" }
            $sType = if ($s.PSObject.Properties["type"])   { $s.type }   else { "" }
            $sNote = if ($s.PSObject.Properties["reason"]) { $s.reason } elseif ($s.PSObject.Properties["note"]) { $s.note } else { "" }
            $analysis.scenario_findings += @{
                step_id = $sId
                type    = $sType
                note    = $sNote
            }
            $analysis.critical_issues += "Step fail: [$sType] $sNote"
        }
    }

    if ($srSkipped -gt 0) {
        $analysis.recommendations += "$srSkipped step di-skip — kemungkinan action belum didaftarkan di InputMap atau game_state belum diimplementasikan"
    }

    if ($scenarioResult.status -eq "pass") {
        Write-Ok "Semua step scenario berhasil"
    } elseif ($scenarioResult.status -eq "error") {
        $errMsg = if ($scenarioResult.PSObject.Properties["error"]) { $scenarioResult.error } else { "unknown error" }
        Write-Warn "Scenario error (bukan step fail): $errMsg"
        $analysis.critical_issues += "Scenario error: $errMsg"
    } else {
        Write-Warn "$srFailed step gagal"
    }
}

# 4c: Analyze game state jika tersedia
$gameStatePath = Join-Path $shotsDir "game_state.json"
if (Test-Path -LiteralPath $gameStatePath) {
    try {
        $gameState = Get-Content -LiteralPath $gameStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Ok "game_state.json tersedia — fase mature"
    } catch {
        Write-Warn "game_state.json tidak bisa dibaca"
        $analysis.recommendations += "game_state.json corrupt atau format tidak valid — cek implementasi _write_game_state()"
    }
} else {
    $analysis.recommendations += "Implementasikan _write_game_state() untuk analisis lebih dalam (fase mature)"
}

# ── FASE GATE: protected-file hard block ──────────────────────────────────────
Write-Phase "GATE" "Cek protected-file violation..."

$effectivePatterns = @(Get-DefaultProtectedPatterns -ReproducingScenario $ReproducingScenario) + @($ProtectedPatterns)
$effectivePatterns = @($effectivePatterns | Select-Object -Unique)
$gateResult = Test-ProtectedFileViolation -RepoPath $ProjectPath -ProtectedPatterns $effectivePatterns -BaseRef $GateBaseRef -PatchRef $PatchRef

if ($gateResult.violated) {
    # Sengaja TIDAK pakai Write-Fail (exit langsung) -- laporan tetap harus ditulis
    # lengkap dengan hasil scenario/visual-diff supaya manusia yang menerima eskalasi
    # punya konteks penuh, bukan cuma "gate gagal".
    Write-Host "[run-analyze] GATE FAIL: patch menyentuh file verifikasi -- eskalasi wajib, tidak lanjut ke merge" -ForegroundColor Red
    foreach ($hit in $gateResult.protected_hits) { Write-Warn "  $hit" }
} else {
    Write-Ok "GATE: tidak ada protected-file violation ($($gateResult.changed_files.Count) file berubah)"
}

# ── TAHAP 3: Scope constraint (allowlist check) ──────────────────────────────
# Dievaluasi SETELAH denylist (di atas) dan hanya jika denylist tidak violated.
# Denylist menang atas allowlist -- fix-request tidak bisa dipakai sebagai celah
# melewati proteksi yang sudah ada di denylist.
$scopeResult = $null
if (-not $gateResult.violated -and $FixLoopMode -and $FixRequestPath -ne "") {
    Write-Phase "SCOPE" "Cek scope constraint dari fix-request..."
    $scopeResult = Test-ScopeViolation -RepoPath $ProjectPath `
        -FixRequestPath $FixRequestPath `
        -BaseRef $GateBaseRef `
        -PatchRef $PatchRef

    if ($scopeResult.error -ne "") {
        Write-Warn "Scope check: $($scopeResult.error)"
    } elseif ($scopeResult.violated) {
        Write-Host "[run-analyze] SCOPE FAIL: patch menyentuh file di luar allowlist fix-request" -ForegroundColor Red
        foreach ($f in $scopeResult.out_of_scope) {
            Write-Warn "  Out-of-scope: $f"
        }
        Write-Info "  Allowed files dari fix-request: $($scopeResult.allowed_files -join ', ')"
        # Scope violation menjadi bagian dari laporan dan mempengaruhi overall_status
        # tapi tidak otomatis override denylist -- denylist sudah diperiksa di atas
        $gateResult.violated = $true
        $gateResult.protected_hits = @($gateResult.protected_hits) + @("SCOPE: file di luar allowlist: $($scopeResult.out_of_scope -join ', ')")
    } else {
        Write-Ok "SCOPE: semua perubahan dalam allowlist fix-request ($($scopeResult.allowed_files.Count) file diizinkan)"
    }
}

# ── FASE 5: REPORT ─────────────────────────────────────────────────────────────
Write-Phase "REPORT" "Membuat laporan..."

$phase3Failed  = $phase3Status -in @("timeout", "error", "stale_result", "compile_error")
$overallStatus = if ($gateResult.violated) { "escalation_required" } `
                 elseif ($phase3Failed) { "run_failed" } `
                 elseif ($analysis.critical_issues.Count -gt 0) { "issues_found" } `
                 else { "clean" }

$report = [ordered]@{
    schema_version   = "1.0"
    generated_at     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    project_name     = $projectName
    project_path     = $ProjectPath
    scenario_used    = (Split-Path $scenarioPath -Leaf)
    overall_status   = $overallStatus
    phases           = [ordered]@{
        observe  = $phase1Status
        generate = $phase2Status
        run      = $phase3Status
        analyze  = @{
            visual_regression = $phase4aStatus
            scenario_results  = if ($scenarioResult) { $scenarioResult.status } else { "not_run" }
        }
        gate     = if ($gateResult.violated) { "violated" } else { "ok" }
    }
    gate             = [ordered]@{
        violated       = $gateResult.violated
        changed_files  = @($gateResult.changed_files)
        protected_hits = @($gateResult.protected_hits)
    }
    scope            = if ($scopeResult) { [ordered]@{
        violated     = $scopeResult.violated
        out_of_scope = @($scopeResult.out_of_scope)
        allowed_files = @($scopeResult.allowed_files)
        fix_request_id = $scopeResult.fix_request_id
        error        = $scopeResult.error
    } } else { $null }
    fix_loop         = if ($FixLoopMode) { [ordered]@{
        enabled          = $true
        fix_request_path = $FixRequestPath
        patch_branch     = $PatchBranch
        max_iterations   = $MaxIterations
    } } else { $null }
    analysis         = $analysis
    manifest_summary = if ($manifest) { [ordered]@{
        telemetry_phase = $manifest.telemetry_phase
        png_count       = $manifest.png_count
        generated_at    = $manifest.generated_at
    } } else { $null }
    scenario_summary = if ($scenarioResult) { [ordered]@{
        status       = $scenarioResult.status
        passed       = if ($scenarioResult.PSObject.Properties["steps_pass"])  { $scenarioResult.steps_pass }  `
                       elseif ($scenarioResult.PSObject.Properties["passed"])  { $scenarioResult.passed }  else { 0 }
        failed       = if ($scenarioResult.PSObject.Properties["steps_fail"])  { $scenarioResult.steps_fail }  `
                       elseif ($scenarioResult.PSObject.Properties["failed"])  { $scenarioResult.failed }  else { 0 }
        skipped      = if ($scenarioResult.PSObject.Properties["steps_skip"])  { $scenarioResult.steps_skip }  `
                       elseif ($scenarioResult.PSObject.Properties["skipped"]) { $scenarioResult.skipped } else { 0 }
        duration_sec = if ($scenarioResult.PSObject.Properties["duration_sec"]) { $scenarioResult.duration_sec } else { $null }
    } } else { $null }
    visual_comparison = if ($diffReport -and $shotsDir -ne "") {
        # Side-by-side before/after PNG paths untuk setiap file yang berubah (REGRESI atau INTENTIONAL).
        # Memungkinkan developer/reviewer melihat perubahan visual tanpa perlu mencari file secara manual.
        # Path: current = shotsDir\<file>, baseline = shotsDir\baseline\<file>
        $baselineDir = Join-Path $shotsDir "baseline"
        $comparisons = [System.Collections.Generic.List[object]]::new()
        foreach ($f in @($diffReport.files | Where-Object { $_.status -in @("REGRESI", "INTENTIONAL") })) {
            $currentPath  = Join-Path $shotsDir $f.file
            $baselinePath = Join-Path $baselineDir $f.file
            $comparisons.Add([ordered]@{
                file          = $f.file
                status        = $f.status
                change_pct    = if ($f.PSObject.Properties["change_pct"]) { $f.change_pct } else { $null }
                current_png   = if (Test-Path -LiteralPath $currentPath)  { $currentPath  } else { $null }
                baseline_png  = if (Test-Path -LiteralPath $baselinePath) { $baselinePath } else { $null }
            })
        }
        @($comparisons)
    } else { $null }
}

# Tulis laporan
if (-not (Test-Path -LiteralPath (Split-Path $OutputReport -Parent) -PathType Container)) {
    New-Item -ItemType Directory -Path (Split-Path $OutputReport -Parent) | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputReport -Encoding UTF8
Write-Ok "Laporan: $OutputReport"

# ── Ringkasan ke stdout ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " RUN-AND-ANALYZE SELESAI" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Status      : $overallStatus" -ForegroundColor $(
    if ($overallStatus -eq "clean") { "Green" }
    elseif ($overallStatus -eq "escalation_required") { "Red" }
    else { "Yellow" }
)
Write-Host " Scenario    : $(Split-Path $scenarioPath -Leaf)"
Write-Host " Harness     : $phase1Status"
Write-Host " Run         : $phase3Status"

if ($gateResult.violated) {
    Write-Host ""
    Write-Host " GATE VIOLATION -- eskalasi wajib, TIDAK boleh merge otomatis:" -ForegroundColor Red
    foreach ($hit in $gateResult.protected_hits) {
        Write-Host "   - $hit" -ForegroundColor Red
    }
}

if ($analysis.critical_issues.Count -gt 0) {
    Write-Host ""
    Write-Host " ISSUES DITEMUKAN:" -ForegroundColor Yellow
    foreach ($i in $analysis.critical_issues) {
        Write-Host "   - $i" -ForegroundColor Yellow
    }
}

if ($analysis.recommendations.Count -gt 0) {
    Write-Host ""
    Write-Host " REKOMENDASI:" -ForegroundColor Cyan
    foreach ($r in $analysis.recommendations) {
        Write-Host "   - $r" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host " Laporan detail: $OutputReport" -ForegroundColor Gray
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# Cleanup worktree jika sukses di-provision -- baik gate pass maupun fail
# Worktree harus selalu dibersihkan agar tidak menumpuk di disk setelah tiap iterasi.
# Cleanup dilakukan SETELAH laporan ditulis supaya laporan tetap tersedia untuk review.
if ($worktreeInfo -and $worktreeInfo.success) {
    Remove-FixLoopWorktree -RepoPath $ProjectPath `
        -WorktreePath $worktreeInfo.worktree_path `
        -BranchName ""  # JANGAN hapus branch -- branch tetap perlu untuk merge jika gate pass
    Write-Info "Worktree dibersihkan: $($worktreeInfo.worktree_path)"
}

# Exit code hard block -- orchestrator fix-loop harus bisa percaya exit code saja
# tanpa parsing JSON untuk tahu apakah lanjut ke merge atau eskalasi ke manusia.
if ($gateResult.violated) { exit 1 }
if ($phase3Failed) { exit 1 }
exit 0
