# =============================================================================
#  visual-review.ps1 -- verdict visual yang AWET
# =============================================================================
#
#  Masalah yang diselesaikan
#  -------------------------
#  visual-diff membandingkan pixel: ia tahu sebuah layar BERUBAH, tapi tidak pernah
#  tahu layar itu BENAR atau SALAH. Cacat seperti teks terpotong, mojibake, tombol
#  tertutup panel, atau kontras yang tak terbaca hanya bisa dinilai dengan melihat --
#  dan penilaian itu selama ini hilang begitu percakapan selesai.
#
#  Tool ini menjadikan penilaian visual sebagai artefak, bukan obrolan:
#    plan   -> daftar (screenshot, klaim) yang BELUM dinilai atau sudah basi
#    record -> simpan verdict dari agent, dipatok ke gambar yang benar-benar dinilai
#    check  -> exit 1 kalau ada verdict fail, atau masih ada yang belum dinilai
#
#  Kenapa dipatok ke gambar
#  ------------------------
#  Verdict menyimpan sha256 gambar saat dinilai. Kalau gambar berubah, verdict TIDAK
#  otomatis berlaku lagi -- itulah bedanya dengan komentar di changelog.
#
#  Tapi patokan sha murni terlalu galak: game dengan screen-shake atau animasi
#  menghasilkan sha berbeda SETIAP run walau tampilannya sama, sehingga semua verdict
#  batal terus dan sistemnya jadi tak terpakai. Karena itu saat sha berbeda, gambar
#  yang dulu dinilai (disimpan di visual-review/judged/) dibandingkan dengan yang baru
#  memakai Get-ImageChangePercent. Di bawah threshold -> verdict dibawa maju, sha
#  diperbarui. Di atas threshold -> ditandai basi dan wajib dinilai ulang.
#
#  Fail-closed: `check` pada proyek yang belum pernah dinilai HARUS gagal, bukan lulus.
#  Diam bukan bukti bahwa tampilannya benar.
# =============================================================================

param(
    [string] $ProjectPath  = "",
    [string] $ShotsDir     = "",
    [string] $ClaimsFile   = "",
    [ValidateSet("plan", "record", "check")]
    [string] $Mode         = "plan",
    [string] $VerdictFile  = "",
    [double] $Threshold    = 2.0,
    [switch] $AllowUnjudged,
    [string] $ImageMagick  = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPs1 = Join-Path $PSScriptRoot "_common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    Write-Host "[review] FAIL _common.ps1 tidak ditemukan di $PSScriptRoot" -ForegroundColor Red
    Write-Host "[review]      Instalasi rusak -- jalankan setup.ps1 lagi." -ForegroundColor Red
    exit 1
}
. $commonPs1

function Write-Step { param($m) Write-Host "[review] $m"      -ForegroundColor Cyan   }
function Write-Ok   { param($m) Write-Host "[review] OK  $m"  -ForegroundColor Green  }
function Write-Warn { param($m) Write-Host "[review] WARN $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "[review] FAIL $m" -ForegroundColor Red    }

# -- 1. Resolve path -----------------------------------------------------------
if ($ProjectPath -eq "" -and $ShotsDir -eq "") { $ProjectPath = (Get-Location).Path }
if ($ShotsDir -eq "") {
    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        Write-Bad "ProjectPath tidak ditemukan: $ProjectPath"; exit 1
    }
    $ShotsDir = Resolve-GodotShotsDir -ProjectPath $ProjectPath
}
if (-not (Test-Path -LiteralPath $ShotsDir)) {
    Write-Bad "ShotsDir tidak ditemukan: $ShotsDir"
    Write-Warn "Jalankan shot-harness lebih dulu supaya ada screenshot untuk dinilai."
    exit 1
}

if ($ClaimsFile -eq "" -and $ProjectPath -ne "") {
    $ClaimsFile = Join-Path $ProjectPath "scenarios\visual-claims.json"
}

$reviewPath   = Join-Path $ShotsDir "visual-review.json"
$judgedDir    = Join-Path $ShotsDir "visual-review\judged"
$worklistPath = Join-Path $ShotsDir "visual-review-worklist.json"

# -- 2. Muat klaim -------------------------------------------------------------
# Tanpa file klaim tidak ada yang bisa dinilai. Ini BUKAN kondisi sukses: kalau
# check tetap lulus di sini, proyek tanpa klaim akan selamanya tampak "visual OK".
if (-not (Test-Path -LiteralPath $ClaimsFile)) {
    Write-Warn "File klaim tidak ada: $ClaimsFile"
    Write-Warn "Salin scenarios-templates/visual-claims.json ke project lalu sesuaikan."
    if ($Mode -eq "check") { Write-Bad "check tanpa klaim = tidak ada bukti visual apa pun"; exit 1 }
    exit 1
}
try {
    $claimsDoc = Get-Content -LiteralPath $ClaimsFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Bad "visual-claims.json tidak valid: $_"; exit 1
}
if (-not ($claimsDoc.PSObject.Properties.Name -contains "claims")) {
    Write-Bad "visual-claims.json tidak punya field 'claims'"; exit 1
}
if ($claimsDoc.PSObject.Properties.Name -contains "threshold_pct") {
    $Threshold = [double]$claimsDoc.threshold_pct
}
$claims = @($claimsDoc.claims)
if ($claims.Count -eq 0) { Write-Bad "Daftar 'claims' kosong"; exit 1 }

# -- 3. Screenshot yang dinilai ------------------------------------------------
# Artefak buatan framework sendiri tidak pernah dinilai: ia bukan layar game.
$pngs = @(Get-ChildItem -LiteralPath $ShotsDir -Filter "*.png" -File |
          Where-Object { $_.Name -notmatch "^(scenario_|aq_|zoom_|diff_)" } |
          Sort-Object Name)
if ($pngs.Count -eq 0) { Write-Bad "Tidak ada screenshot layar game di $ShotsDir"; exit 1 }

function Test-ClaimApplies {
    param($Claim, [string] $FileName)
    if (-not ($Claim.PSObject.Properties.Name -contains "applies_to")) { return $true }
    $pat = $Claim.applies_to
    if ($null -eq $pat) { return $true }
    foreach ($p in @($pat)) {
        if ([string]$p -eq "*") { return $true }
        if ($FileName -like [string]$p) { return $true }
    }
    return $false
}

# -- 4. Muat state sebelumnya --------------------------------------------------
$review = $null
if (Test-Path -LiteralPath $reviewPath) {
    try { $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Warn "visual-review.json rusak -- dianggap kosong"; $review = $null }
}

# Di bawah Set-StrictMode, `$obj.PSObject.Properties.Name` MELEMPAR kalau koleksi
# propertinya kosong -- dan itu kondisi normal di sini: file yang belum punya satu pun
# verdict tersimpan sebagai "claims": {}. Enumerasi eksplisit tidak pernah melempar.
function Get-PropNames {
    param($Obj)
    if ($null -eq $Obj) { return @() }
    return @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-StoredClaim {
    param([string] $File, [string] $ClaimId)
    if ($null -eq $review) { return $null }
    if (-not ((Get-PropNames $review) -contains "files")) { return $null }
    $filesObj = $review.files
    if (-not ((Get-PropNames $filesObj) -contains $File)) { return $null }
    $entry = $filesObj.$File
    if (-not ((Get-PropNames $entry) -contains "claims")) { return $null }
    $claimsObj = $entry.claims
    if (-not ((Get-PropNames $claimsObj) -contains $ClaimId)) { return $null }
    return $claimsObj.$ClaimId
}

# -- 5. Bangun state baru ------------------------------------------------------
$magick = ""
try { $magick = Resolve-ImageMagick -ImageMagick $ImageMagick } catch { $magick = "" }

$newFiles = [ordered]@{}
$work     = [System.Collections.Generic.List[object]]::new()
$nJudged = 0; $nStale = 0; $nUnjudged = 0; $nFailed = 0; $nCarried = 0

# Klaim yang polanya tidak cocok dengan SATU PUN screenshot yang ada.
#
# Pencacah di bawah dibangun dengan mengiterasi screenshot lalu mencari klaim yang berlaku.
# Konsekuensinya, klaim yang tidak punya berkas sama sekali tidak pernah masuk pencacah mana
# pun -- ia hanya muncul di angka "Klaim: N" di header lalu lenyap. Terukur: dua klaim, satu
# screenshot, hasilnya "Dinilai: 1 | Belum: 0" dan `check` keluar 0 dengan "semua klaim punya
# verdict yang berlaku".
#
# Pemicunya justru kondisi yang sering terjadi di proyek ini: tur screenshot berhenti di
# tengah jalan, layar yang dijanjikan tidak pernah ditulis, dan klaim tentangnya diam-diam
# berhenti diperiksa. Itu persis saat verifikasi visual paling dibutuhkan.
#
# Opt-out per klaim: "optional": true, untuk layar yang memang tidak selalu muncul.
$orphanClaims = @()
foreach ($c in $claims) {
    $isOptional = (($c.PSObject.Properties | ForEach-Object { $_.Name }) -contains "optional") -and [bool]$c.optional
    if ($isOptional) { continue }
    $matched = $false
    foreach ($png in $pngs) {
        if (Test-ClaimApplies -Claim $c -FileName $png.Name) { $matched = $true; break }
    }
    if (-not $matched) { $orphanClaims += [string]$c.id }
}
$nOrphan = $orphanClaims.Count

foreach ($png in $pngs) {
    $sha = (Get-FileHash -LiteralPath $png.FullName -Algorithm SHA256).Hash
    $fileClaims = [ordered]@{}

    foreach ($c in $claims) {
        if (-not (Test-ClaimApplies -Claim $c -FileName $png.Name)) { continue }
        $cid  = [string]$c.id
        $ques = if ($c.PSObject.Properties.Name -contains "question") { [string]$c.question } else { $cid }
        $prev = Get-StoredClaim -File $png.Name -ClaimId $cid

        if ($null -eq $prev) {
            $nUnjudged++
            $work.Add([ordered]@{ file = $png.Name; path = $png.FullName; claim_id = $cid
                                  question = $ques; reason = "belum_dinilai"; change_pct = $null })
            continue
        }

        $prevSha = if ((Get-PropNames $prev) -contains "judged_sha256") { [string]$prev.judged_sha256 } else { "" }
        if ($prevSha -eq $sha) {
            # Gambar identik dengan yang dinilai -> verdict tetap berlaku apa adanya.
            $fileClaims[$cid] = $prev
            $nJudged++
            if ([string]$prev.verdict -eq "fail") { $nFailed++ }
            continue
        }

        # Gambar berubah. Seberapa jauh? Bandingkan dengan salinan yang dulu dinilai.
        $judgedCopy = Join-Path $judgedDir $png.Name
        $delta = -1.0
        if ($magick -ne "" -and (Test-Path -LiteralPath $judgedCopy)) {
            $delta = Get-ImageChangePercent -PathA $judgedCopy -PathB $png.FullName -ImageMagickExe $magick
        }
        # Verdict FAIL tidak pernah dibawa maju. Bawa-maju ada untuk menahan derau -- game
        # dengan screen-shake menghasilkan gambar sedikit berbeda tiap run, dan tanpa
        # toleransi semua verdict batal terus. Tapi toleransi yang sama akan mempertahankan
        # vonis yang sudah usang, karena SEBUAH PERBAIKAN BISA MENENTUKAN SECARA VISUAL
        # NAMUN KECIL DALAM HITUNGAN PIXEL. Terukur pada jimat: menghapus banner yang
        # menimpa judul modal dan mencerahkan satu label alasan keduanya mengubah < 2%
        # pixel, sehingga kedua verdict 'fail' bertahan padahal bug-nya sudah hilang.
        # Melaporkan bug yang sudah diperbaiki merusak kepercayaan sama parahnya dengan
        # melewatkan bug. Jadi: pass boleh dibawa maju, fail selalu dinilai ulang.
        $bolehBawaMaju = ($delta -ge 0 -and $delta -le $Threshold -and [string]$prev.verdict -ne "fail")
        if ($bolehBawaMaju) {
            # Perubahan di bawah ambang -- penilaian lama masih masuk akal. Bawa maju,
            # tapi CATAT bahwa ia dibawa maju supaya tidak terlihat seperti penilaian baru.
            #
            # judged_sha256 TIDAK diperbarui, dan salinan yang dinilai TIDAK ditimpa.
            # Versi sebelumnya melakukan keduanya, dan itu memindahkan titik acuan setiap
            # kali membawa maju -- sehingga penyimpangan menumpuk tanpa batas: 1,9% + 1,9%
            # + 1,9% ... masing-masing lolos ambang, tetapi setelah puluhan run gambarnya
            # bisa sudah sama sekali lain sementara verdict-nya ikut terbawa. Itu
            # meniadakan seluruh guna penyematan sha. Sekarang selisih SELALU diukur
            # terhadap gambar yang benar-benar pernah dinilai, sehingga penyimpangan
            # terkurung permanen di bawah threshold.
            $carried = [ordered]@{
                verdict           = [string]$prev.verdict
                note              = [string]$prev.note
                judged_at         = [string]$prev.judged_at
                judged_sha256     = $prevSha   # tetap: gambar yang BENAR-BENAR dinilai
                applies_to_sha256 = $sha       # gambar terkini yang masih tercakup verdict ini
                drift_pct         = $delta     # selisih terhadap gambar yang dinilai, bukan terhadap run sebelumnya
            }
            $fileClaims[$cid] = [pscustomobject]$carried
            $nJudged++; $nCarried++
            if ([string]$prev.verdict -eq "fail") { $nFailed++ }
        } else {
            $nStale++
            $reasonTxt = if ($delta -lt 0) { "gambar_berubah" } else { "berubah_melebihi_threshold" }
            $work.Add([ordered]@{ file = $png.Name; path = $png.FullName; claim_id = $cid
                                  question = $ques; reason = $reasonTxt
                                  change_pct = $(if ($delta -ge 0) { $delta } else { $null })
                                  verdict_lama = [string]$prev.verdict })
        }
    }

    if ($fileClaims.Count -gt 0) {
        $newFiles[$png.Name] = [ordered]@{ image_sha256 = $sha; claims = $fileClaims }
    } else {
        $newFiles[$png.Name] = [ordered]@{ image_sha256 = $sha; claims = [ordered]@{} }
    }
}

# -- 6. Mode record ------------------------------------------------------------
if ($Mode -eq "record") {
    if ($VerdictFile -eq "" -or -not (Test-Path -LiteralPath $VerdictFile)) {
        Write-Bad "-Mode record membutuhkan -VerdictFile yang ada"; exit 1
    }
    try { $vdoc = Get-Content -LiteralPath $VerdictFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Bad "File verdict tidak valid: $_"; exit 1 }
    if (-not ($vdoc.PSObject.Properties.Name -contains "verdicts")) {
        Write-Bad "File verdict tidak punya field 'verdicts'"; exit 1
    }

    if (-not (Test-Path -LiteralPath $judgedDir)) { New-Item -ItemType Directory -Path $judgedDir -Force | Out-Null }
    $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $applied = 0; $rejected = @()

    foreach ($v in @($vdoc.verdicts)) {
        $vf = [string]$v.file; $vc = [string]$v.claim_id
        $vv = ([string]$v.verdict).ToLower()
        if ($vv -notin @("pass", "fail", "na")) {
            $rejected += "${vf}/${vc}: verdict '$vv' tidak dikenal (pakai pass|fail|na)"; continue
        }
        if (-not $newFiles.Contains($vf)) { $rejected += "${vf}: bukan screenshot yang dinilai"; continue }
        $target = Get-Item -LiteralPath (Join-Path $ShotsDir $vf) -ErrorAction SilentlyContinue
        if ($null -eq $target) { $rejected += "${vf}: file tidak ada"; continue }
        $sha = (Get-FileHash -LiteralPath $target.FullName -Algorithm SHA256).Hash

        $note = if ($v.PSObject.Properties.Name -contains "note") { [string]$v.note } else { "" }
        # Verdict fail tanpa catatan tidak berguna bagi siapa pun yang membacanya nanti.
        if ($vv -eq "fail" -and $note.Trim() -eq "") {
            $rejected += "${vf}/${vc}: verdict fail wajib menyertakan 'note'"; continue
        }

        $entry = $newFiles[$vf]
        $entry.claims[$vc] = [pscustomobject][ordered]@{
            verdict = $vv; note = $note; judged_at = $ts; judged_sha256 = $sha
        }
        Copy-Item -LiteralPath $target.FullName -Destination (Join-Path $judgedDir $vf) -Force
        $applied++
    }

    foreach ($r in $rejected) { Write-Warn "DITOLAK  $r" }
    Write-Ok "$applied verdict dicatat"
    if ($rejected.Count -gt 0) { Write-Warn "$($rejected.Count) verdict ditolak" }

    # Hitung ulang ringkasan dari state akhir
    $nJudged = 0; $nFailed = 0; $nUnjudged = 0
    foreach ($fname in $newFiles.Keys) {
        foreach ($c in $claims) {
            if (-not (Test-ClaimApplies -Claim $c -FileName $fname)) { continue }
            $cid = [string]$c.id
            if ($newFiles[$fname].claims.Contains($cid)) {
                $nJudged++
                if ([string]$newFiles[$fname].claims[$cid].verdict -eq "fail") { $nFailed++ }
            } else { $nUnjudged++ }
        }
    }
    $nStale = 0
}

# -- 7. Tulis state ------------------------------------------------------------
$total = $nJudged + $nStale + $nUnjudged
$out = [ordered]@{
    schema_version = "1.0"
    generated_at   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    shots_dir      = $ShotsDir
    claims_file    = $ClaimsFile
    threshold_pct  = $Threshold
    summary        = [ordered]@{
        total = $total; judged = $nJudged; carried_forward = $nCarried
        stale = $nStale; unjudged = $nUnjudged; failed = $nFailed
        orphan = $nOrphan; orphan_claims = @($orphanClaims)
    }
    files = $newFiles
}
$out | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reviewPath -Encoding UTF8

# -- 8. Keluaran per mode ------------------------------------------------------
Write-Host ""
Write-Step "Klaim  : $($claims.Count) | Screenshot: $($pngs.Count) | Threshold bawa-maju: $Threshold%"
Write-Step "Dinilai: $nJudged (dibawa maju: $nCarried) | Basi: $nStale | Belum: $nUnjudged | GAGAL: $nFailed | Tanpa berkas: $nOrphan"
if ($nOrphan -gt 0) {
    Write-Warn "Klaim tanpa screenshot yang cocok: $($orphanClaims -join ', ')"
    Write-Warn "Layar yang dijanjikan klaim itu tidak ada di ShotsDir -- tur screenshot mungkin berhenti di tengah jalan."
}
Write-Host ""

if ($Mode -eq "plan") {
    $wl = [ordered]@{
        generated_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        shots_dir    = $ShotsDir
        petunjuk     = "Nilai setiap item dengan MELIHAT gambar di 'path'. Tulis hasilnya ke file JSON " +
                       "berisi {verdicts:[{file,claim_id,verdict,note}]} lalu jalankan tool ini dengan " +
                       "-Mode record -VerdictFile <file>. verdict: pass|fail|na. 'fail' WAJIB pakai note."
        items        = @($work)
    }
    $wl | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $worklistPath -Encoding UTF8

    if ($work.Count -eq 0) {
        Write-Ok "Tidak ada yang perlu dinilai -- semua klaim punya verdict yang masih berlaku."
    } else {
        Write-Step "$($work.Count) item perlu dinilai:"
        foreach ($w in ($work | Select-Object -First 25)) {
            $extra = if ($null -ne $w.change_pct) { " (berubah $($w.change_pct)%)" } else { "" }
            Write-Host ("  [{0,-26}] {1}{2}" -f $w.claim_id, $w.file, $extra) -ForegroundColor Gray
        }
        if ($work.Count -gt 25) { Write-Host "  ... dan $($work.Count - 25) lagi" -ForegroundColor DarkGray }
        Write-Step "Worklist: $worklistPath"
    }
    exit 0
}

if ($Mode -eq "check") {
    $problems = @()
    if ($nFailed -gt 0)   { $problems += "$nFailed klaim ber-verdict FAIL" }
    # Klaim tanpa berkas TIDAK ikut -AllowUnjudged: "belum sempat dinilai" dan "layarnya
    # tidak pernah dihasilkan" adalah dua masalah berbeda, dan yang kedua biasanya berarti
    # tur screenshot rusak. Opt-out-nya per klaim ("optional": true), bukan per run.
    if ($nOrphan -gt 0)   { $problems += "$nOrphan klaim tidak punya screenshot yang cocok ($($orphanClaims -join ', '))" }
    if (-not $AllowUnjudged) {
        if ($nUnjudged -gt 0) { $problems += "$nUnjudged klaim belum pernah dinilai" }
        if ($nStale -gt 0)    { $problems += "$nStale klaim basi (gambar berubah melebihi threshold)" }
    }
    if ($problems.Count -eq 0) {
        Write-Ok "Semua klaim visual punya verdict yang berlaku dan tidak ada yang gagal."
        exit 0
    }
    foreach ($p in $problems) { Write-Bad $p }
    # Tampilkan yang gagal supaya laporan tidak perlu dibuka manual
    foreach ($fname in $newFiles.Keys) {
        foreach ($cid in $newFiles[$fname].claims.Keys) {
            $cl = $newFiles[$fname].claims[$cid]
            if ([string]$cl.verdict -eq "fail") {
                Write-Host ("  FAIL {0} :: {1} -- {2}" -f $fname, $cid, $cl.note) -ForegroundColor Red
            }
        }
    }
    exit 1
}

Write-Ok "Laporan: $reviewPath"
exit 0
