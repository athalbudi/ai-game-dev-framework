# feedback-bridge.ps1
# Menghubungkan teks feedback playtester ke screenshot, komponen UI, dan lokasi kode.
# v1.1 — tambah frequency weighting per profil dan resolution tracking
#
# Usage:
#   & feedback-bridge.ps1 -FeedbackFile <path> -ProjectPath <path> [-TopN 5] [-MinScore 2]
#   & feedback-bridge.ps1 -FeedbackText "panel musuh tidak punya countdown" -ProjectPath <path>
#   & feedback-bridge.ps1 -FeedbackFile <path> -ProjectPath <path> -OutputJson
#   & feedback-bridge.ps1 -FeedbackFile <path> -ProjectPath <path> -ProfileDelimiter "--- Profil"

param(
    [string]$FeedbackFile       = "",
    [string]$FeedbackText       = "",
    [string]$ProjectPath        = "",
    [string]$ScreenIndexPath    = "",
    [string]$ProfileDelimiter   = "--- Profil",
    [int]   $TopN               = 10,
    [int]   $MinScore           = 2,
    [int]   $MinProfil          = 1,
    [switch]$OutputJson,
    [switch]$Verbose
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

function Write-Bridge { param($msg) Write-Host "[bridge] $msg" -ForegroundColor Cyan }
function Write-Hit    { param($msg) Write-Host "  + $msg" -ForegroundColor Green }
function Write-Gap    { param($msg) Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Miss   { param($msg) Write-Host "  . $msg" -ForegroundColor DarkGray }
function Write-Res    { param($msg) Write-Host "  * $msg" -ForegroundColor Magenta }

# --- Resolve paths ---
if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if ($ScreenIndexPath -eq "") { $ScreenIndexPath = Join-Path $ProjectPath "screen-index.json" }

if (-not (Test-Path $ScreenIndexPath)) {
    Write-Error ("screen-index.json tidak ditemukan di: " + $ScreenIndexPath)
    exit 1
}
$index = Get-Content $ScreenIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Bridge ("Loaded screen-index: " + $index.project + " build " + $index.build)

# --- Load feedback text ---
$feedbackRaw = ""
if ($FeedbackFile -ne "" -and (Test-Path $FeedbackFile)) {
    $feedbackRaw = Get-Content $FeedbackFile -Raw -Encoding UTF8
    $sizeKB = [math]::Round((Get-Item $FeedbackFile).Length / 1KB, 1)
    Write-Bridge ("Feedback file: " + $FeedbackFile + " (" + $sizeKB + " KB)")
} elseif ($FeedbackText -ne "") {
    $feedbackRaw = $FeedbackText
    $preview = $feedbackRaw.Substring(0, [Math]::Min(80, $feedbackRaw.Length))
    Write-Bridge ("Feedback text: " + $preview + "...")
} else {
    Write-Error "Berikan -FeedbackFile atau -FeedbackText"
    exit 1
}

$feedbackLower = $feedbackRaw.ToLower()

# --- Deteksi dan split per profil ---
# Jika delimiter ditemukan, split ke profil; jika tidak, seluruh file = 1 profil
$profiles = @()
# Gunakan regex yang hanya match delimiter pembuka (--- Profil N ---) bukan END
$delimPattern = [regex]::Escape($ProfileDelimiter) + '\s+\d+\s+---'
if ([regex]::IsMatch($feedbackRaw, $delimPattern)) {
    # Split hanya pada delimiter PEMBUKA: --- Profil N ---
    $rawProfiles = [regex]::Split($feedbackRaw, $delimPattern)
    foreach ($p in $rawProfiles) {
        $trimmed = $p.Trim()
        # Filter bagian header file dan blok kosong
        # Abaikan blok yang terlihat seperti header dokumen atau separator
        if ($trimmed.Length -gt 50 -and -not ($trimmed -match '^=====|^-----')) {
            $profiles += $trimmed.ToLower()
        }
    }
    Write-Bridge ("Mode: frequency weighting | " + $profiles.Count + " profil terdeteksi")
} else {
    $profiles += $feedbackLower
    Write-Bridge ("Mode: keyword count (tidak ada delimiter profil) | 1 blok")
}
$totalProfil = $profiles.Count
Write-Bridge ("MinScore: " + $MinScore + " | MinProfil: " + $MinProfil + " | TopN: " + $TopN)

# --- Resolve ShotsDir ---
$shotsDir = ""
$manifestPath = Join-Path $ProjectPath "shots-manifest.json"
if (-not (Test-Path $manifestPath)) {
    $projectName = (Split-Path $ProjectPath -Leaf).ToUpper()
    $godotShots  = "$env:APPDATA\Godot\app_userdata\$projectName\shots"
    if (Test-Path "$godotShots\shots-manifest.json") {
        $manifestPath = "$godotShots\shots-manifest.json"
    }
}
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $shotsDir = $manifest.shots_dir
        Write-Bridge ("ShotsDir: " + $shotsDir + " (dari manifest)")
    } catch {}
}
if ($shotsDir -eq "" -or -not (Test-Path $shotsDir)) {
    $projectName = (Split-Path $ProjectPath -Leaf).ToUpper()
    $fallback    = "$env:APPDATA\Godot\app_userdata\$projectName\shots"
    if (Test-Path $fallback) {
        $shotsDir = $fallback
        Write-Bridge ("ShotsDir: " + $shotsDir + " (fallback)")
    } else {
        Write-Bridge "ShotsDir tidak ditemukan -- screenshot paths tidak akan di-resolve"
    }
}

# --- Scoring helpers ---

# Hitung keyword score pada satu teks
function Get-KeywordScore {
    param([string]$text, [array]$keywords)
    $score   = 0
    $matched = @()
    foreach ($kw in $keywords) {
        if ($kw -ne "" -and $text.Contains($kw.ToLower())) {
            $score++
            $matched += $kw
        }
    }
    return @{ score = $score; matched = $matched }
}

# Hitung berapa PROFIL distinct yang menyebut setidaknya 1 keyword
function Get-ProfilCount {
    param([array]$profilList, [array]$keywords)
    $count   = 0
    $allMatched = @()
    foreach ($p in $profilList) {
        $hit = $false
        foreach ($kw in $keywords) {
            if ($kw -ne "" -and $p.Contains($kw.ToLower())) {
                $hit = $true
                if ($allMatched -notcontains $kw) { $allMatched += $kw }
            }
        }
        if ($hit) { $count++ }
    }
    return @{ count = $count; matched = $allMatched }
}

function Resolve-ShotPath {
    param([string]$shotFile)
    if ($shotsDir -ne "") {
        $p = Join-Path $shotsDir $shotFile
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Helper: baca resolution_status dari issue jika ada
function Get-ResolutionStatus {
    param($issue)
    if ($issue.PSObject.Properties.Name -contains "resolution_status") {
        return $issue.resolution_status
    }
    return $null
}

# --- Match global issues ---
$globalMatches = @()
if ($index.PSObject.Properties.Name -contains "feedback_keywords_global") {
    foreach ($prop in $index.feedback_keywords_global.PSObject.Properties) {
        $issue       = $prop.Value
        $kwResult    = Get-KeywordScore -text $feedbackLower -keywords $issue.keywords
        $prResult    = Get-ProfilCount  -profilList $profiles -keywords $issue.keywords
        $resolution  = Get-ResolutionStatus $issue

        # Filter: harus memenuhi MinScore DAN MinProfil
        if ($kwResult.score -ge $MinScore -and $prResult.count -ge $MinProfil) {
            $pct = if ($totalProfil -gt 0) { [math]::Round($prResult.count * 100.0 / $totalProfil) } else { 0 }
            $globalMatches += [PSCustomObject]@{
                issue_id        = $prop.Name
                score           = $kwResult.score
                profil_count    = $prResult.count
                profil_total    = $totalProfil
                profil_pct      = $pct
                matched_kw      = $kwResult.matched
                screens         = $issue.screens
                components      = $issue.components
                resolution      = $resolution
            }
        }
    }
}
$globalMatches = $globalMatches | Sort-Object profil_count -Descending | Select-Object -First $TopN

# --- Match screens ---
$screenMatches = @()
foreach ($screen in $index.screens) {
    $screenScore   = 0
    $screenProfil  = 0
    $screenMatched = @()
    $componentHits = @()

    foreach ($comp in $screen.components) {
        $kwResult = Get-KeywordScore -text $feedbackLower -keywords $comp.keywords
        $prResult = Get-ProfilCount  -profilList $profiles -keywords $comp.keywords
        if ($kwResult.score -gt 0) {
            $screenScore  += $kwResult.score
            $screenProfil  = [math]::Max($screenProfil, $prResult.count)
            $screenMatched += $kwResult.matched
            $isGap     = $comp.PSObject.Properties.Name -contains "gap" -and $comp.gap -eq $true
            $gapDesc   = if ($comp.PSObject.Properties.Name -contains "gap_description") { $comp.gap_description } else { "" }
            $keyIssues = if ($comp.PSObject.Properties.Name -contains "key_feedback_issues") { $comp.key_feedback_issues } else { @() }
            $componentHits += [PSCustomObject]@{
                name        = $comp.name
                description = $comp.description
                file        = $comp.file
                score       = $kwResult.score
                profil_count= $prResult.count
                matched_kw  = $kwResult.matched
                is_gap      = $isGap
                gap_desc    = $gapDesc
                key_issues  = $keyIssues
            }
        }
    }

    if ($screenScore -ge $MinScore -and $screenProfil -ge $MinProfil) {
        $resolvedShots = @()
        foreach ($sf in $screen.shot_files) {
            $p = Resolve-ShotPath $sf
            if ($p) { $resolvedShots += $p }
        }
        $pct = if ($totalProfil -gt 0) { [math]::Round($screenProfil * 100.0 / $totalProfil) } else { 0 }
        $screenMatches += [PSCustomObject]@{
            screen_id    = $screen.screen_id
            description  = $screen.description
            score        = $screenScore
            profil_count = $screenProfil
            profil_pct   = $pct
            shot_files   = $screen.shot_files
            shot_paths   = $resolvedShots
            goto_func    = $screen.goto_func
            render_files = $screen.render_files
            matched_kw   = ($screenMatched | Select-Object -Unique)
            comp_hits    = ($componentHits | Sort-Object profil_count -Descending)
        }
    }
}
$screenMatches = $screenMatches | Sort-Object profil_count -Descending | Select-Object -First $TopN

# --- Build result ---
$allShots = @()
foreach ($sm in $screenMatches) { $allShots += $sm.shot_paths }
$allShots = $allShots | Select-Object -Unique

$gapCount = 0
foreach ($sm in $screenMatches) {
    foreach ($ch in $sm.comp_hits) { if ($ch.is_gap) { $gapCount++ } }
}

$summaryText = ("" + $globalMatches.Count + " masalah, " +
                $screenMatches.Count + " screen relevan, " +
                $totalProfil + " profil, " +
                $allShots.Count + " screenshot, " +
                $gapCount + " gap")

if ($OutputJson) {
    $out_obj = [ordered]@{
        schema_version  = "1.1"
        timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        project         = $index.project
        build           = $index.build
        feedback_source = if ($FeedbackFile -ne "") { $FeedbackFile } else { "inline" }
        total_profil    = $totalProfil
        shots_dir       = $shotsDir
        global_issues   = @($globalMatches)
        screen_matches  = @($screenMatches)
        all_shot_paths  = @($allShots)
        summary         = $summaryText
    }
    $out_obj | ConvertTo-Json -Depth 10
    exit 0
}

# --- Human-readable output ---
Write-Host ""
Write-Host "========================================================" -ForegroundColor DarkGray
Write-Host "  FEEDBACK BRIDGE REPORT v1.1" -ForegroundColor White
Write-Host ("  Project: " + $index.project + "  Build: " + $index.build) -ForegroundColor DarkGray
Write-Host ("  Profil: " + $totalProfil + "  Mode: " + $(if ($totalProfil -gt 1) { "frequency weighting" } else { "keyword count" })) -ForegroundColor DarkGray
Write-Host "========================================================" -ForegroundColor DarkGray
Write-Host ""

if ($globalMatches.Count -gt 0) {
    Write-Host "MASALAH YANG TERIDENTIFIKASI:" -ForegroundColor Yellow
    foreach ($gi in $globalMatches) {
        $label = "[" + $gi.profil_count + "/" + $gi.profil_total + " profil = " + $gi.profil_pct + "%]"
        Write-Host ("  " + $label + " " + $gi.issue_id) -ForegroundColor Cyan
        Write-Host ("      Keyword : " + ($gi.matched_kw -join ", ")) -ForegroundColor DarkGray
        Write-Host ("      Screen  : " + ($gi.screens -join ", ")) -ForegroundColor DarkGray
        Write-Host ("      Komponen: " + ($gi.components -join ", ")) -ForegroundColor DarkGray
        if ($gi.resolution) {
            $resColor = if ($gi.resolution -eq "resolved") { "Green" } elseif ($gi.resolution -eq "persistent") { "Red" } else { "Yellow" }
            Write-Host ("      Status  : " + $gi.resolution.ToUpper()) -ForegroundColor $resColor
        }
    }
    Write-Host ""
}

if ($screenMatches.Count -gt 0) {
    Write-Host "LAYAR YANG RELEVAN:" -ForegroundColor Yellow
    foreach ($sm in $screenMatches) {
        $label = "[" + $sm.profil_count + "/" + $totalProfil + " = " + $sm.profil_pct + "%]"
        Write-Host ""
        Write-Host ("  " + $label + " " + $sm.screen_id.ToUpper()) -ForegroundColor White
        $descPreview = $sm.description.Substring(0, [Math]::Min(80, $sm.description.Length))
        Write-Host ("      " + $descPreview) -ForegroundColor DarkGray
        Write-Host ("      Kode: " + ($sm.render_files -join ", ")) -ForegroundColor DarkGray

        if ($sm.shot_paths.Count -gt 0) {
            Write-Host "      Screenshot:" -ForegroundColor DarkGray
            foreach ($sp in $sm.shot_paths) { Write-Hit ("        " + $sp) }
        } else {
            foreach ($sf in $sm.shot_files) { Write-Miss ("        " + $sf + " (tidak ditemukan)") }
        }

        if ($sm.comp_hits.Count -gt 0) {
            Write-Host "      Komponen:" -ForegroundColor DarkGray
            foreach ($ch in $sm.comp_hits) {
                $compLabel = "[" + $ch.profil_count + "/" + $totalProfil + "]"
                if ($ch.is_gap) {
                    $gdesc = $ch.gap_desc.Substring(0, [Math]::Min(80, $ch.gap_desc.Length))
                    Write-Gap ("        GAP " + $compLabel + ": " + $ch.name + " -- " + $gdesc)
                } else {
                    Write-Hit ("        " + $compLabel + " " + $ch.name + " (" + $ch.file + ")")
                    foreach ($ki in $ch.key_issues) {
                        $kiPreview = $ki.Substring(0, [Math]::Min(100, $ki.Length))
                        Write-Host ("          -> " + $kiPreview) -ForegroundColor Yellow
                    }
                }
                if ($Verbose) {
                    Write-Host ("          kw: " + ($ch.matched_kw -join ", ")) -ForegroundColor DarkGray
                }
            }
        }
    }
    Write-Host ""
}

Write-Host ("SUMMARY: " + $summaryText) -ForegroundColor Green
Write-Host ""

if ($allShots.Count -gt 0) {
    Write-Host "SCREENSHOT UNTUK DIBACA AI:" -ForegroundColor Yellow
    foreach ($sp in $allShots) { Write-Host ("  " + $sp) -ForegroundColor Cyan }
    Write-Host ""
}

Write-Host "========================================================" -ForegroundColor DarkGray