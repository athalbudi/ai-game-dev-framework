<#
.SYNOPSIS
    Visual regression diff: bandingkan screenshot terbaru vs baseline.

.DESCRIPTION
    Bandingkan PNG di ShotsDir vs BaselineDir. Gunakan ImageMagick jika tersedia,
    fallback ke MD5 hash jika tidak ada.

    Output:
      <ShotsDir>\diff\diff-report.json

    Baseline history disimpan di <ShotsDir>\baseline\history\
    Maksimum 5 snapshot history. Gunakan -Against untuk diff ke snapshot lama.

.PARAMETER ShotsDir
    Path folder screenshot terbaru. Default: baca dari shots-manifest.json.

.PARAMETER BaselineDir
    Path folder baseline. Default: <ShotsDir>\baseline\

.PARAMETER Against
    Nama subfolder di history untuk diff (contoh: "20260719_143245").
    Jika diisi, BaselineDir di-override ke <ShotsDir>\baseline\history\<Against>
    Gunakan /baseline status untuk melihat daftar snapshot yang tersedia.

.PARAMETER Threshold
    Persen pixel berubah yang dianggap regresi. Default: 1.0

.PARAMETER ImageMagick
    Path ke ImageMagick executable. Jika kosong, dicari otomatis.

.PARAMETER IgnoreConfig
    Path ke file JSON yang mendefinisikan region yang diabaikan saat diff.
    Default: <ProjectPath>\shots.zoom.json (field "ignore_regions").
    Format JSON:
    {
      "ignore_regions": [
        { "src": "01_main_menu.png", "x": 650, "y": 10, "w": 70, "h": 20, "reason": "timestamp" },
        { "src": "*", "x": 0, "y": 0, "w": 50, "h": 20, "reason": "fps counter" }
      ]
    }
    Field "src" mendukung wildcard "*" untuk semua file.
    Region yang cocok akan di-mask hitam di kedua gambar sebelum dibandingkan.
    Tambahkan field "region_thresholds" untuk threshold per-region yang berbeda dari global:
    {
      "ignore_regions": [...],
      "region_thresholds": [
        { "src": "01_hud.png", "x": 0, "y": 0, "w": 720, "h": 100, "threshold": 0.1 },
        { "src": "*",          "x": 0, "y": 0, "w": 50,  "h": 20,  "threshold": 5.0 }
      ]
    }
    region_thresholds tidak me-mask area — hanya menerapkan threshold berbeda untuk area tersebut.

.EXAMPLE
    # Diff vs baseline aktif
    & "$env:USERPROFILE\.config\kilo\tools\visual-diff.ps1" `
        -ShotsDir "C:\dev\mygame\shots"

.EXAMPLE
    # Diff dengan ignore_regions dari shots.zoom.json
    & "$env:USERPROFILE\.config\kilo\tools\visual-diff.ps1" `
        -ShotsDir "C:\dev\mygame\shots" `
        -IgnoreConfig "C:\dev\mygame\shots.zoom.json"

.EXAMPLE
    # Diff vs snapshot history tertentu
    & "$env:USERPROFILE\.config\kilo\tools\visual-diff.ps1" `
        -ShotsDir "C:\dev\mygame\shots" `
        -Against "20260719_143245"
#>

[CmdletBinding()]
param(
    [string] $ShotsDir            = "",
    [string] $BaselineDir         = "",
    [string] $Against             = "",
    [double] $Threshold           = 1.0,
    [string] $ImageMagick         = "",
    [string] $IgnoreConfig        = "",
    [string] $NormalizeResolution = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "[diff] $msg"         -ForegroundColor Cyan   }
function Write-Ok   { param($msg) Write-Host "[diff] OK  $msg"     -ForegroundColor Green  }
function Write-Warn { param($msg) Write-Host "[diff] WARN $msg"    -ForegroundColor Yellow }
function Write-Reg  { param($msg) Write-Host "[diff] REGRESI $msg" -ForegroundColor Red    }
function Write-Fail { param($msg) Write-Host "[diff] FAIL $msg"    -ForegroundColor Red; exit 1 }

# -- 1. Resolve ShotsDir -------------------------------------------------------
if ($ShotsDir -eq "") {
    $manifestPath = Join-Path (Get-Location).Path "shots-manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $ShotsDir = $manifest.shots_dir
        Write-Step "ShotsDir dari manifest: $ShotsDir"
    } else {
        Write-Fail "ShotsDir tidak diisi dan shots-manifest.json tidak ditemukan."
    }
}

if (-not (Test-Path -LiteralPath $ShotsDir -PathType Container)) {
    Write-Fail "ShotsDir tidak ditemukan: $ShotsDir"
}

# -- 2. Resolve BaselineDir ----------------------------------------------------
if ($Against -ne "") {
    # Diff vs snapshot history tertentu
    $historyDir = Join-Path $ShotsDir "baseline\history"
    $BaselineDir = Join-Path $historyDir $Against
    if (-not (Test-Path -LiteralPath $BaselineDir -PathType Container)) {
        Write-Fail "Snapshot history '$Against' tidak ditemukan di: $historyDir`nGunakan /baseline status untuk melihat snapshot yang tersedia."
    }
    Write-Step "Diff vs snapshot history: $Against"
} elseif ($BaselineDir -eq "") {
    $BaselineDir = Join-Path $ShotsDir "baseline"
}

if (-not (Test-Path -LiteralPath $BaselineDir -PathType Container)) {
    Write-Warn "BaselineDir tidak ditemukan: $BaselineDir"
    Write-Warn "Baseline belum pernah di-set. Gunakan /baseline set untuk membuat baseline."
    exit 0
}

# -- 2b. Tampilkan info baseline yang digunakan --------------------------------
$baselineManifestPath = Join-Path $BaselineDir "baseline-manifest.json"
if (Test-Path -LiteralPath $baselineManifestPath) {
    try {
        $bm = Get-Content -LiteralPath $baselineManifestPath -Raw | ConvertFrom-Json
        $setAt = if ($bm.PSObject.Properties.Name -contains "baseline_set_at") { $bm.baseline_set_at } `
                 elseif ($bm.PSObject.Properties.Name -contains "timestamp") { $bm.timestamp } `
                 else { "unknown" }
        Write-Step "Baseline diset pada: $setAt"
    } catch { }
}

# -- 2c. Load ignore_regions --------------------------------------------------
# Baca dari IgnoreConfig (parameter) atau auto-detect dari shots.zoom.json
$ignoreRegions = @()   # array of { src, x, y, w, h, reason }
$cfgObj        = $null   # full config object (untuk region_thresholds; berbeda nama dari param $IgnoreConfig)

function Get-IgnoreRegionsForFile {
    param([string]$fileName, [array]$regions)
    $matched = @()
    foreach ($r in $regions) {
        $pattern = $r.src
        if ($pattern -eq "*" -or $fileName -like $pattern) {
            $matched += $r
        }
    }
    return $matched
}

if ($IgnoreConfig -ne "") {
    # Parameter eksplisit
    if (Test-Path -LiteralPath $IgnoreConfig) {
        try {
            $ic = Get-Content -LiteralPath $IgnoreConfig -Raw | ConvertFrom-Json
            $cfgObj = $ic   # simpan full object untuk region_thresholds (nama berbeda dari param $IgnoreConfig)
            if ($ic.PSObject.Properties.Name -contains "ignore_regions") {
                $ignoreRegions = @($ic.ignore_regions)
                Write-Step "ignore_regions dimuat dari: $IgnoreConfig ($($ignoreRegions.Count) region)"
            } else {
                Write-Warn "IgnoreConfig tidak memiliki field 'ignore_regions': $IgnoreConfig"
            }
        } catch {
            Write-Warn "Gagal membaca IgnoreConfig: $_"
        }
    } else {
        Write-Warn "IgnoreConfig tidak ditemukan: $IgnoreConfig"
    }
} else {
    # Auto-detect dari shots.zoom.json di parent ProjectPath (satu level di atas ShotsDir,
    # atau di working directory)
    $autoZoomCandidates = @(
        (Join-Path (Get-Location).Path "shots.zoom.json"),
        (Join-Path (Split-Path $ShotsDir -Parent) "shots.zoom.json")
    )
    foreach ($candidate in $autoZoomCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            try {
                $ic = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
                if ($ic.PSObject.Properties.Name -contains "ignore_regions") {
                    $cfgObj  = $ic   # simpan full object
                    $ignoreRegions = @($ic.ignore_regions)
                    Write-Step "ignore_regions dimuat dari: $candidate ($($ignoreRegions.Count) region)"
                    break
                }
            } catch { }
        }
    }
}

# Load region_thresholds dari config (threshold per area, berbeda dari global Threshold)
$regionThresholds = @()   # array of { src, x, y, w, h, threshold }

if ($cfgObj -ne $null -and $cfgObj.PSObject.Properties.Name -contains "region_thresholds") {
    $regionThresholds = @($cfgObj.region_thresholds)
    Write-Step "region_thresholds dimuat: $($regionThresholds.Count) region dengan threshold kustom"
}

# Load intentional_changes dari config
# Format: { "src": "01_title.png", "reason": "Updated branding", "version": "0.20" }
# File yang match akan downgrade REGRESI -> INTENTIONAL (tidak dihitung sebagai regresi)
$intentionalChanges = @()   # array of { src, reason, version }

if ($cfgObj -ne $null -and $cfgObj.PSObject.Properties.Name -contains "intentional_changes") {
    $intentionalChanges = @($cfgObj.intentional_changes)
    Write-Step "intentional_changes dimuat: $($intentionalChanges.Count) file ditandai intentional"
}

function Get-IntentionalChange {
    param([string]$fileName, [array]$changes)
    foreach ($c in $changes) {
        $pattern = $c.src
        if ($pattern -eq "*" -or $fileName -like $pattern) {
            return $c
        }
    }
    return $null
}

# Helper: ambil effective threshold untuk file tertentu berdasarkan region_thresholds
function Get-EffectiveThreshold {
    param([string]$fileName, [double]$globalThreshold, [array]$regionThresholds)
    # Kembalikan threshold terendah dari semua region yang match untuk file ini
    # (conservative: gunakan threshold paling ketat yang berlaku)
    $minThreshold = $globalThreshold
    foreach ($r in $regionThresholds) {
        $pattern = $r.src
        if ($pattern -eq "*" -or $fileName -like $pattern) {
            $rt = [double]$r.threshold
            if ($rt -lt $minThreshold) {
                $minThreshold = $rt
            }
        }
    }
    return $minThreshold
}

# Helper: buat gambar sementara dengan region ter-mask hitam (butuh ImageMagick)
function New-MaskedCopy {
    param(
        [string] $srcPath,
        [string] $outPath,
        [array]  $regions,
        [string] $imageMagickExe,
        [bool]   $isV7
    )
    # Mulai dari sumber
    Copy-Item -LiteralPath $srcPath -Destination $outPath -Force

    foreach ($r in $regions) {
        $x = [int]$r.x
        $y = [int]$r.y
        $w = [int]$r.w
        $h = [int]$r.h
        $geometry = "${w}x${h}+${x}+${y}"
        if ($isV7) {
            $args = "convert `"$outPath`" -fill black -draw `"rectangle ${x},${y} $($x+$w-1),$($y+$h-1)`" `"$outPath`""
        } else {
            $args = "`"$outPath`" -fill black -draw `"rectangle ${x},${y} $($x+$w-1),$($y+$h-1)`" `"$outPath`""
        }
        $psi2 = New-Object System.Diagnostics.ProcessStartInfo
        $psi2.FileName               = $imageMagickExe
        $psi2.Arguments              = $args
        $psi2.RedirectStandardError  = $true
        $psi2.UseShellExecute        = $false
        $psi2.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $p2 = [System.Diagnostics.Process]::Start($psi2)
        $p2.WaitForExit()
    }
}

# -- 3. Deteksi ImageMagick ----------------------------------------------------
$useImageMagick = $false

if ($ImageMagick -ne "") {
    if (Test-Path -LiteralPath $ImageMagick) {
        $useImageMagick = $true
        Write-Ok "ImageMagick dari parameter: $ImageMagick"
    } else {
        Write-Warn "ImageMagick path tidak valid, fallback ke hash comparison"
    }
} else {
    $imCandidates = @("magick", "compare")
    foreach ($c in $imCandidates) {
        $found = Get-Command $c -ErrorAction SilentlyContinue
        if ($found -and $found.Source -ne "") {
            $ImageMagick = $found.Source
            $useImageMagick = $true
            Write-Ok "ImageMagick ditemukan: $ImageMagick"
            break
        }
    }
    if (-not $useImageMagick) {
        $globPaths = @(
            "C:\Program Files\ImageMagick-7*\magick.exe",
            "C:\Program Files\ImageMagick-6*\compare.exe"
        )
        foreach ($g in $globPaths) {
            $found = Get-Item $g -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $ImageMagick = $found.FullName
                $useImageMagick = $true
                Write-Ok "ImageMagick ditemukan: $ImageMagick"
                break
            }
        }
    }
}

if (-not $useImageMagick) {
    Write-Warn "ImageMagick tidak ditemukan, menggunakan MD5 hash comparison"
    Write-Warn "Install ImageMagick untuk pixel-level diff: https://imagemagick.org"
}

# -- 4. Buat folder diff -------------------------------------------------------
$diffDir = Join-Path $ShotsDir "diff"
if (-not (Test-Path -LiteralPath $diffDir)) {
    New-Item -ItemType Directory -Path $diffDir | Out-Null
}


# -- 4b. Normalisasi resolusi (opsional) ----------------------------------------
# Jika -NormalizeResolution diisi dan ImageMagick tersedia, resize semua gambar ke
# ukuran target sebelum diff. Hasil resize disimpan di folder normalized/, tidak
# mengubah file asli. Berguna ketika screenshot diambil di resolusi berbeda antar build.
$normalizeDir = ""
if ($NormalizeResolution -ne "" -and $useImageMagick) {
    $normalizeDir = Join-Path $diffDir "normalized"
    if (-not (Test-Path -LiteralPath $normalizeDir)) {
        New-Item -ItemType Directory -Path $normalizeDir | Out-Null
    }
    if ($NormalizeResolution -match "^\d+x\d+$") {
        Write-Step "Normalisasi resolusi ke $NormalizeResolution..."
    } else {
        Write-Warn "Format NormalizeResolution tidak valid (contoh: 1920x1080). Diabaikan."
        $NormalizeResolution = ""
        $normalizeDir = ""
    }
} elseif ($NormalizeResolution -ne "" -and -not $useImageMagick) {
    Write-Warn "NormalizeResolution diabaikan: ImageMagick tidak tersedia."
    $NormalizeResolution = ""
}

# Helper: kembalikan path gambar yang sudah dinormalisasi, atau path asli jika tidak
function Get-NormalizedPath {
    param(
        [System.IO.FileInfo] $imgFile,
        [string] $normDir,
        [string] $resolution,
        [string] $imageMagickExe,
        [bool]   $isV7
    )
    if ($normDir -eq "" -or $resolution -eq "") { return $imgFile.FullName }
    $outPath = Join-Path $normDir $imgFile.Name
    if (-not (Test-Path -LiteralPath $outPath)) {
        $w = $resolution.Split("x")[0]
        $h = $resolution.Split("x")[1]
        $resArgs = if ($isV7) {
            "convert `"$($imgFile.FullName)`" -resize ${w}x${h}! `"$outPath`""
        } else {
            "`"$($imgFile.FullName)`" -resize ${w}x${h}! `"$outPath`""
        }
        $psiR = New-Object System.Diagnostics.ProcessStartInfo
        $psiR.FileName              = $imageMagickExe
        $psiR.Arguments             = $resArgs
        $psiR.UseShellExecute       = $false
        $psiR.WindowStyle           = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $pR = [System.Diagnostics.Process]::Start($psiR)
        $pR.WaitForExit()
    }
    return $outPath
}

# -- 5. Kumpulkan file ---------------------------------------------------------
        $currentPngs  = @(Get-ChildItem -LiteralPath $ShotsDir   -Filter "*.png" | Where-Object { $_.Name -notmatch "^scenario_" } | Sort-Object Name)
        $baselinePngs = @(Get-ChildItem -LiteralPath $BaselineDir -Filter "*.png" | Sort-Object Name)

$baselineMap = @{}
foreach ($b in $baselinePngs) {
    $baselineMap[$b.Name] = $b
}

$results     = [System.Collections.Generic.List[object]]::new()
$countOk     = 0
$countReg    = 0
$countNew    = 0
$countMiss   = 0
$countIntent = 0  # perubahan intentional — tidak dihitung sebagai regresi

Write-Step "Membandingkan $($currentPngs.Count) current vs $($baselinePngs.Count) baseline..."
Write-Host ""

# -- 6. Bandingkan current vs baseline -----------------------------------------
foreach ($cur in $currentPngs) {
    if ($cur.Name -like "zoom_*") { continue }
    if ($cur.Name -like "diff_*") { continue }

    $entry = [ordered]@{
        file       = $cur.Name
        status     = ""
        change_pct = 0.0
        diff_image = ""
        note       = ""
    }

    if (-not $baselineMap.ContainsKey($cur.Name)) {
        $entry.status = "FILE_BARU"
        $entry.note   = "Tidak ada di baseline"
        $countNew++
        Write-Warn "BARU    $($cur.Name)"
        $results.Add($entry)
        continue
    }

    $baseFile = $baselineMap[$cur.Name].FullName

    if ($useImageMagick) {
        $diffOut = Join-Path $diffDir ("diff_" + $cur.Name)
        $isV7    = ($ImageMagick -like "*magick*") -and ($ImageMagick -notlike "*compare*")

        # -- ignore_regions: buat masked copy sebelum diff ---------------
        $fileIgnoreRegions = Get-IgnoreRegionsForFile -fileName $cur.Name -regions $ignoreRegions
        $curPathForDiff  = $cur.FullName
        $basePathForDiff = $baseFile
        $maskedDir       = Join-Path $diffDir "masked"
        if (@($fileIgnoreRegions).Count -gt 0) {
            if (-not (Test-Path -LiteralPath $maskedDir)) {
                New-Item -ItemType Directory -Path $maskedDir | Out-Null
            }
            $maskedCur  = Join-Path $maskedDir ("cur_"  + $cur.Name)
            $maskedBase = Join-Path $maskedDir ("base_" + $cur.Name)
            New-MaskedCopy -srcPath $cur.FullName -outPath $maskedCur  `
                           -regions $fileIgnoreRegions -imageMagickExe $ImageMagick -isV7 $isV7
            New-MaskedCopy -srcPath $baseFile     -outPath $maskedBase `
                           -regions $fileIgnoreRegions -imageMagickExe $ImageMagick -isV7 $isV7
            $curPathForDiff  = $maskedCur
            $basePathForDiff = $maskedBase
            $entry["ignored_regions"] = @($fileIgnoreRegions).Count
        }
        # ----------------------------------------------------------------

        if ($isV7) {
            $imArgs = "compare -metric AE `"$basePathForDiff`" `"$curPathForDiff`" `"$diffOut`""
        } else {
            $imArgs = "-metric AE `"$basePathForDiff`" `"$curPathForDiff`" `"$diffOut`""
        }

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName              = $ImageMagick
            $psi.Arguments             = $imArgs
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute       = $false
            $psi.WindowStyle           = [System.Diagnostics.ProcessWindowStyle]::Hidden

            $proc    = [System.Diagnostics.Process]::Start($psi)
            $errText = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()

            $pixelsDiff = 0.0
            # Regex menangkap angka desimal dan notasi ilmiah (mis. 6.6214e+09 dari ImageMagick Q16-HDRI)
            if ($errText -match "([\d.]+(?:[eE][+\-]?\d+)?)") {
                $pixelsDiff = [double]$Matches[1]
            }

            # Hitung total pixel dari dimensi aktual file PNG, bukan nilai hardcoded.
            # Gunakan ImageMagick identify untuk membaca lebar x tinggi.
            $totalPixels = 0
            try {
                $identArgs = if ($isV7) { "identify -format `"%w %h`" `"$($cur.FullName)`"" } `
                                        else { "`"$($cur.FullName)`" -format `"%w %h`" info:" }
                $psiId = New-Object System.Diagnostics.ProcessStartInfo
                $psiId.FileName              = $ImageMagick
                $psiId.Arguments             = $identArgs
                $psiId.RedirectStandardOutput = $true
                $psiId.UseShellExecute       = $false
                $psiId.WindowStyle           = [System.Diagnostics.ProcessWindowStyle]::Hidden
                $procId = [System.Diagnostics.Process]::Start($psiId)
                $dimOut = $procId.StandardOutput.ReadToEnd().Trim()
                $procId.WaitForExit()
                if ($dimOut -match "^(\d+)\s+(\d+)$") {
                    $totalPixels = [int]$Matches[1] * [int]$Matches[2]
                }
            } catch { }
            # Fallback: ukuran default jika identify gagal (mis. resolusi Godot default 720×1600)
            if ($totalPixels -le 0) { $totalPixels = 720 * 1600 }

            # Normalisasi AE ke persentase 0–100.
            # Pada build ImageMagick Q16-HDRI, AE bukan cacah pixel biasa melainkan
            # nilai quantum-scaled yang bisa jauh > totalPixels. Clamp ke 100 agar
            # threshold (default 1%) dan region_thresholds tetap bermakna di semua build.
            # Pada build non-HDRI (Q8/Q16), AE = cacah pixel → rasio tetap benar.
            $rawChangePct  = ($pixelsDiff / $totalPixels) * 100
            $changePct     = [math]::Round([math]::Min(100.0, $rawChangePct), 3)

            $entry.change_pct = $changePct
            $entry.diff_image = "diff\diff_" + $cur.Name

            # Per-region threshold: gunakan threshold efektif untuk file ini
            $effectiveThreshold = Get-EffectiveThreshold -fileName $cur.Name `
                -globalThreshold $Threshold -regionThresholds $regionThresholds
            $thresholdNote = if ($effectiveThreshold -ne $Threshold) {
                " [threshold kustom: $($effectiveThreshold)%]"
            } else { "" }

            if ($changePct -gt $effectiveThreshold) {
                # Cek apakah perubahan ini intentional
                $intentional = Get-IntentionalChange -fileName $cur.Name -changes $intentionalChanges
                if ($intentional -ne $null) {
                    $entry.status = "INTENTIONAL"
                    $entry["effective_threshold"] = $effectiveThreshold
                    $entry["intentional_reason"] = $intentional.reason
                    if ($intentional.PSObject.Properties.Name -contains "version") { $entry["intentional_version"] = $intentional.version }
                    $countIntent++
                    Write-Ok ("INTENTIONAL $($cur.Name) - " + $changePct + "% berubah [" + $intentional.reason + "]")
                } else {
                    $entry.status = "REGRESI"
                    $entry["effective_threshold"] = $effectiveThreshold
                    $countReg++
                    $ignoreNote = if (@($fileIgnoreRegions).Count -gt 0) { " [$(@($fileIgnoreRegions).Count) region diabaikan]" } else { "" }
                    Write-Reg ("$($cur.Name) - " + $changePct + "% pixel berubah (threshold: " + $effectiveThreshold + "%)$ignoreNote$thresholdNote")
                }
            } else {
                $entry.status = "OK"
                $entry["effective_threshold"] = $effectiveThreshold
                $countOk++
                $ignoreNote = if (@($fileIgnoreRegions).Count -gt 0) { " [$(@($fileIgnoreRegions).Count) region diabaikan]" } else { "" }
                Write-Ok ("OK      $($cur.Name) - " + $changePct + "% pixel berubah$ignoreNote$thresholdNote")
            }
        } catch {
            $entry.status = "ERROR"
            $entry.note   = "ImageMagick gagal: " + $_
            Write-Warn ("ERROR   $($cur.Name): " + $_)
        }
    } else {
        $hashCur  = (Get-FileHash -LiteralPath $cur.FullName -Algorithm MD5).Hash
        $hashBase = (Get-FileHash -LiteralPath $baseFile     -Algorithm MD5).Hash

        if ($hashCur -eq $hashBase) {
            $entry.status     = "OK"
            $entry.change_pct = 0.0
            $entry.note       = "Hash identik"
            $countOk++
            Write-Ok "OK      $($cur.Name) - identik"
        } else {
            $intentional = Get-IntentionalChange -fileName $cur.Name -changes $intentionalChanges
            if ($intentional -ne $null) {
                $entry.status     = "INTENTIONAL"
                $entry.change_pct = -1
                $entry.note       = "Hash berbeda — intentional: " + $intentional.reason
                $entry["intentional_reason"] = $intentional.reason
                if ($intentional.PSObject.Properties.Name -contains "version") { $entry["intentional_version"] = $intentional.version }
                $countIntent++
                Write-Ok "INTENTIONAL $($cur.Name) - hash berbeda [" + $intentional.reason + "]"
            } else {
                $entry.status     = "BERUBAH"
                $entry.change_pct = -1
                $entry.note       = "Hash berbeda (install ImageMagick untuk persentase pixel)"
                $countReg++
                Write-Reg "$($cur.Name) - hash berbeda"
            }
        }
    }

    $results.Add($entry)
}

# -- 7. Cek baseline yang hilang dari current ----------------------------------
foreach ($base in $baselinePngs) {
    if ($base.Name -like "zoom_*") { continue }
    if ($base.Name -like "diff_*") { continue }
    $found = $currentPngs | Where-Object { $_.Name -eq $base.Name }
    if (-not $found) {
        $results.Add([ordered]@{
            file       = $base.Name
            status     = "HILANG"
            change_pct = 0.0
            diff_image = ""
            note       = "Ada di baseline tapi tidak di current"
        })
        $countMiss++
        Write-Warn "HILANG  $($base.Name)"
    }
}

# -- 8. Tulis diff-report.json -------------------------------------------------
$report = [ordered]@{
    generated_at  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    shots_dir     = $ShotsDir
    baseline_dir  = $BaselineDir
    threshold_pct = $Threshold
    summary       = [ordered]@{
        total       = $results.Count
        ok          = $countOk
        regressions = $countReg
        intentional = $countIntent
        new_files   = $countNew
        missing     = $countMiss
    }
    files = $results
}

$reportPath = Join-Path $diffDir "diff-report.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8

# -- 9. Ringkasan --------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "[diff] Ringkasan diff:"                              -ForegroundColor Cyan
Write-Host "  OK        : $countOk"                             -ForegroundColor Green

if ($countReg -gt 0) {
    Write-Host "  Regresi   : $countReg"   -ForegroundColor Red
} else {
    Write-Host "  Regresi   : $countReg"   -ForegroundColor Green
}

Write-Host "  File baru : $countNew"       -ForegroundColor Yellow

if ($countMiss -gt 0) {
    Write-Host "  Hilang    : $countMiss"  -ForegroundColor Yellow
} else {
    Write-Host "  Hilang    : $countMiss"  -ForegroundColor Gray
}

Write-Host "  Threshold : $Threshold%"     -ForegroundColor Gray
Write-Host "  Laporan   : $reportPath"     -ForegroundColor White
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

if ($countReg -gt 0) {
    Write-Host ""
    Write-Host "[diff] Ada $countReg regresi visual. Periksa diff-report.json" -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "[diff] Tidak ada regresi visual." -ForegroundColor Green
    exit 0
}
