# =============================================================================
#  explore-minimize.ps1 -- perkecil jejak eksplorasi jadi repro minimal
# =============================================================================
#
#  Step explore bisa mengklik 40 tombol lalu melaporkan "invariant X dilanggar".
#  Informasi itu benar tetapi nyaris tidak bisa dipakai: yang dibutuhkan bukan
#  "40 klik lalu jebol", melainkan KLIK MANA yang menyebabkannya.
#
#  Tool ini menjalankan ulang subset dari jejak itu sampai menemukan urutan terpendek
#  yang masih melanggar invariant yang sama. Keluarannya scenario yang bisa langsung
#  dijalankan -- 40 klik bisa menyusut jadi 3, dan 3 klik adalah sesuatu yang bisa dibaca
#  manusia maupun dijadikan test regresi.
#
#  Prosesnya murni mekanis: tidak ada penilaian, tidak butuh model. Justru karena itu
#  ia layak berada di framework dan bukan di kepala siapa pun.
#
#  DUA HAL YANG SENGAJA DIPUTUSKAN BEGINI
#
#  1. Baseline diverifikasi lebih dulu, dan gagal tertutup.
#     Replay bisa saja TIDAK mereproduksi: state yang menempel di file vault, animasi
#     yang bergantung waktu, atau RNG yang tidak ter-seed. Memperkecil jejak yang tidak
#     reproducible menghasilkan file yang kelihatan berguna tapi tidak pernah bekerja --
#     dan itu lebih buruk daripada tidak menghasilkan apa-apa. Kalau jejak penuh saja
#     tidak melanggar, tool ini berhenti dan mengatakan alasannya.
#
#  2. Setiap kandidat dijalankan di PROSES GODOT BARU.
#     Memutar ulang di dalam satu proses akan mewarisi state dari percobaan sebelumnya,
#     dan hasil minimisasinya jadi dusta. Lebih lambat, tapi ini satu-satunya cara
#     hasilnya berarti.
# =============================================================================

param(
    [string] $ProjectPath = "",
    [string] $ShotsDir    = "",
    [string] $ReplayFile  = "",
    [string] $InvariantId = "",
    [int]    $MaxRuns     = 40,
    [int]    $Timeout     = 90,
    [string] $GodotExe    = "",
    [switch] $SkipGreedy,
    [switch] $NoStateReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPs1 = Join-Path $PSScriptRoot "_common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    Write-Host "[min] FAIL _common.ps1 tidak ditemukan di $PSScriptRoot" -ForegroundColor Red
    exit 1
}
. $commonPs1

function Write-Step { param($m) Write-Host "[min] $m"      -ForegroundColor Cyan   }
function Write-Ok   { param($m) Write-Host "[min] OK  $m"  -ForegroundColor Green  }
function Write-Warn { param($m) Write-Host "[min] WARN $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "[min] FAIL $m" -ForegroundColor Red    }

# ── 1. Resolve ────────────────────────────────────────────────────────────────
if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath "project.godot"))) {
    Write-Bad "Bukan project Godot: $ProjectPath"; exit 1
}
if ($ShotsDir   -eq "") { $ShotsDir   = Resolve-GodotShotsDir -ProjectPath $ProjectPath }
if ($ReplayFile -eq "") { $ReplayFile = Join-Path $ShotsDir "explore_replay.json" }
if ($GodotExe   -eq "") { $GodotExe   = Resolve-GodotExecutable }
if ($GodotExe -eq "" -or -not (Test-Path -LiteralPath $GodotExe)) {
    Write-Bad "Godot tidak ditemukan. Gunakan -GodotExe."; exit 1
}
if (-not (Test-Path -LiteralPath $ReplayFile)) {
    Write-Bad "Jejak tidak ditemukan: $ReplayFile"
    Write-Warn "Jalankan scenario dengan step explore lebih dulu; jejak hanya ditulis saat invariant dilanggar."
    exit 1
}

$replay = Get-Content -LiteralPath $ReplayFile -Raw -Encoding UTF8 | ConvertFrom-Json
$allSteps = @($replay.steps)
# Langkah pembuka (seed_override, wait_frames) SELALU dipertahankan: ia bukan bagian dari
# jejak yang diperkecil, melainkan syarat agar klik pertama mendarat di layar yang benar.
# Jejak baru ditulis sebagai click_button (menyebut APA yang ditekan); mouse_click tetap
# didukung supaya jejak lama masih bisa diperkecil.
$clickTypes = @("click_button", "mouse_click")
$preamble = @($allSteps | Where-Object { $clickTypes -notcontains $_.type })
$clicks   = @($allSteps | Where-Object { $clickTypes -contains $_.type })
if ($clicks.Count -eq 0) { Write-Bad "Jejak tidak memuat satu pun langkah klik"; exit 1 }

# ── 2. Invariant target ───────────────────────────────────────────────────────
$resultPath = Join-Path $ShotsDir "scenario_result.json"
if ($InvariantId -eq "") {
    if (Test-Path -LiteralPath $resultPath) {
        $lastRes = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $vs = @($lastRes.invariant_violations)
        if ($vs.Count -gt 0) { $InvariantId = [string]$vs[0].id }
    }
}
if ($InvariantId -eq "") {
    Write-Bad "Tidak bisa menentukan invariant target. Berikan -InvariantId."
    exit 1
}

Write-Step "Project   : $ProjectPath"
Write-Step "Jejak     : $($clicks.Count) klik (+$($preamble.Count) langkah pembuka)"
Write-Step "Target    : invariant '$InvariantId'"
Write-Step "Anggaran  : $MaxRuns run Godot"

# ── 3. Menjalankan satu kandidat ──────────────────────────────────────────────
$candPath  = Join-Path $ShotsDir "explore_min_candidate.json"
$runCount  = 0
$runLog    = [System.Collections.Generic.List[object]]::new()

# Invariant inline dari jejak ikut dibawa ke setiap kandidat. Yang game-wide dimuat sendiri
# oleh runner; yang inline hanya ada di file jejak, dan tanpa disalin ke kandidat, seluruh
# minimisasi berjalan tanpa aturan yang sedang diselidiki.
$replayInvariants = @()
if ((@($replay.PSObject.Properties | ForEach-Object { $_.Name }) -contains "invariants")) {
    $replayInvariants = @($replay.invariants)
}

# Setiap kandidat HARUS berangkat dari keadaan awal yang sama. Game menyimpan kemajuan di
# user:// (mis. scenario_vault.json), dan run pertama mengubahnya -- sehingga run kedua
# memulai dari layar judul yang isinya berbeda dan klik pada koordinat yang sama mengenai
# tombol lain. Hasil minimisasi yang didapat dari kondisi awal yang berubah-ubah adalah
# dusta. Snapshot diambil sekali lalu dikembalikan sebelum tiap run -- memulihkan, bukan
# menghapus, supaya tidak ada data pengguna yang hilang.
$userDir  = Split-Path $ShotsDir -Parent
$snapDir  = Join-Path $ShotsDir "explore_min_state"
$snapshot = @()
if (-not $NoStateReset -and (Test-Path -LiteralPath $userDir)) {
    if (Test-Path -LiteralPath $snapDir) { Remove-Item -LiteralPath $snapDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $snapDir -Force
    $snapshot = @(Get-ChildItem -LiteralPath $userDir -File -ErrorAction SilentlyContinue)
    foreach ($s in $snapshot) { Copy-Item -LiteralPath $s.FullName -Destination $snapDir -Force }
    Write-Step "State awal disimpan: $($snapshot.Count) file dari $userDir"
}

function Reset-UserState {
    if ($NoStateReset -or $snapshot.Count -eq 0) { return }
    foreach ($s in $snapshot) {
        $src = Join-Path $snapDir $s.Name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $s.FullName -Force }
    }
}

function Test-Candidate {
    param([array] $ClickSubset, [string] $Label)

    if ($script:runCount -ge $MaxRuns) { return $null }   # anggaran habis
    $script:runCount++

    $steps = @($preamble) + @($ClickSubset)
    $doc = [ordered]@{
        scenario_id = "explore_min"
        description = "Kandidat minimisasi otomatis -- jangan disunting tangan."
    }
    if ($replayInvariants.Count -gt 0) { $doc["invariants"] = $replayInvariants }
    $doc["steps"] = $steps
    $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $candPath -Encoding UTF8

    Reset-UserState
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    $p = Start-Process $GodotExe `
        -ArgumentList "--path", "`"$ProjectPath`"", "--", "--scenario", "user://shots/explore_min_candidate.json" `
        -PassThru -NoNewWindow -ErrorAction SilentlyContinue
    if ($p) {
        $p.Handle | Out-Null
        if (-not $p.WaitForExit($Timeout * 1000)) { $null = Stop-ProcessTree -Process $p }
    }

    $hit = $false
    if (Test-Path -LiteralPath $resultPath) {
        try {
            $r = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $hit = @(@($r.invariant_violations) | Where-Object { [string]$_.id -eq $InvariantId }).Count -gt 0
        } catch { }
    }
    $script:runLog.Add([ordered]@{ run = $script:runCount; label = $Label
                                   clicks = $ClickSubset.Count; reproduced = $hit })
    Write-Host ("  run {0,2}  {1,-22} {2,3} klik -> {3}" -f `
        $script:runCount, $Label, $ClickSubset.Count, $(if ($hit) { "JEBOL" } else { "-" })) -ForegroundColor Gray
    return $hit
}

# ── 4. Baseline: jejak penuh HARUS mereproduksi ───────────────────────────────
Write-Host ""
Write-Step "Verifikasi baseline (jejak penuh)..."
$base = Test-Candidate -ClickSubset $clicks -Label "baseline penuh"
if ($base -ne $true) {
    Write-Host ""
    Write-Bad "Jejak penuh TIDAK mereproduksi pelanggaran '$InvariantId'."
    Write-Warn "Minimisasi dihentikan -- memperkecil jejak yang tidak reproducible hanya"
    Write-Warn "menghasilkan file yang tampak berguna tapi tidak pernah bekerja."
    Write-Warn "Penyebab tersering: state menempel di file vault antar-run, animasi yang"
    Write-Warn "bergantung waktu, atau RNG yang tidak ter-seed. Beri seed pada step explore,"
    Write-Warn "dan pastikan game memakai vault terpisah saat --scenario."
    exit 1
}
Write-Ok "Baseline mereproduksi -- minimisasi bisa dilanjutkan"

# ── 5. Fase 1: bisection prefix ───────────────────────────────────────────────
# Pelanggaran terjadi pada satu titik di jejak; klik SESUDAH titik itu hampir selalu
# tidak relevan. Memotong ekor lebih dulu jauh lebih murah (O(log n)) daripada mencoba
# membuang satu per satu, dan biasanya sudah memangkas sebagian besar jejak.
Write-Host ""
Write-Step "Fase 1 -- bisection prefix"
$lo = 1; $hi = $clicks.Count; $bestPrefix = $clicks
while ($lo -lt $hi) {
    if ($runCount -ge $MaxRuns) { Write-Warn "Anggaran run habis di fase 1"; break }
    $mid = [math]::Floor(($lo + $hi) / 2)
    $cand = @($clicks[0..($mid - 1)])
    $ok = Test-Candidate -ClickSubset $cand -Label "prefix $mid"
    if ($null -eq $ok) { break }
    if ($ok) { $hi = $mid; $bestPrefix = $cand } else { $lo = $mid + 1 }
}
Write-Ok "Prefix terpendek yang masih jebol: $($bestPrefix.Count) klik"

# ── 6. Fase 2: pembuangan serakah ─────────────────────────────────────────────
# Sisa klik di dalam prefix belum tentu semuanya perlu. Satu lintasan membuang satu per
# satu; yang pembuangannya tidak mengubah hasil berarti memang tidak relevan.
$minimal = $bestPrefix
if (-not $SkipGreedy -and $bestPrefix.Count -gt 1) {
    Write-Host ""
    Write-Step "Fase 2 -- pembuangan jendela berurutan"
    # Membuang SATU klik saja tidak cukup begitu langkah menyebut label alih-alih koordinat.
    # Navigasi datang berpasangan: "masuk Candi" lalu "Back". Membuang salah satunya membuat
    # pasangannya gagal -- tombol "Back" tidak ada di layar judul -- sehingga subset ditolak
    # dan tidak ada satu klik pun yang bisa dibuang. Terukur pada jimat: pembuangan tunggal
    # berhenti di 5 dari 5, padahal repro sebenarnya cuma satu klik.
    #
    # Karena itu jendela berurutan ikut dicoba, dari yang terpendek. Ukuran dibatasi supaya
    # biayanya tetap terkendali; jejak panjang yang butuh lebih dalam bisa menaikkan -MaxRuns.
    $maxWindow = [math]::Min(4, $minimal.Count - 1)
    for ($w = 1; $w -le $maxWindow; $w++) {
        $improved = $true
        while ($improved) {
            $improved = $false
            $i = 0
            while ($i + $w -le $minimal.Count) {
                if ($runCount -ge $MaxRuns) { break }
                if ($minimal.Count -le 1) { break }
                $trial = @()
                for ($k = 0; $k -lt $minimal.Count; $k++) {
                    if ($k -lt $i -or $k -ge ($i + $w)) { $trial += $minimal[$k] }
                }
                $ok = Test-Candidate -ClickSubset $trial -Label "buang ${w}x @$($i + 1)"
                if ($null -eq $ok) { break }
                if ($ok) { $minimal = $trial; $improved = $true } else { $i++ }
            }
            if ($runCount -ge $MaxRuns) { break }
        }
        if ($runCount -ge $MaxRuns) { Write-Warn "Anggaran run habis di fase 2"; break }
    }
}

# ── 7. Hasil ──────────────────────────────────────────────────────────────────
$reproPath = Join-Path $ShotsDir "explore_repro.json"
[ordered]@{
    scenario_id = "explore_repro"
    description = "Urutan klik TERPENDEK yang masih melanggar invariant '$InvariantId'. " +
                  "Dihasilkan otomatis dari explore_replay.json oleh explore-minimize.ps1. " +
                  "Layak dijadikan test regresi: kalau bug-nya diperbaiki, scenario ini harus lulus."
    minimized_from = $clicks.Count
    invariant   = $InvariantId
    godot_runs  = $runCount
    invariants  = $replayInvariants
    steps       = (@($preamble) + @($minimal))
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reproPath -Encoding UTF8

# State pengguna dikembalikan ke kondisi sebelum minimisasi dimulai.
Reset-UserState
Remove-Item -LiteralPath $candPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Step "==================================================="
Write-Ok "$($clicks.Count) klik  ->  $($minimal.Count) klik  ($runCount run Godot)"
Write-Step "Urutan minimal:"
$n = 0
foreach ($c in $minimal) {
    $n++
    $names = @($c.PSObject.Properties | ForEach-Object { $_.Name })
    $lbl = if ($names -contains "label")   { $c.label }
      elseif ($names -contains "comment") { $c.comment }
      else                                { "($($c.x),$($c.y))" }
    Write-Host ("   {0}. {1}" -f $n, $lbl) -ForegroundColor White
}
Write-Step "Repro  : $reproPath"
Write-Step "==================================================="
exit 0
