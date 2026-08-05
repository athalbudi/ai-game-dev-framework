# =============================================================================
#  game-doctor.ps1 -- pemeriksaan statis terhadap PROJECT GAME
# =============================================================================
#
#  doctor.ps1 memeriksa kesehatan INSTALASI framework. Tool ini memeriksa game-nya.
#
#  Alasan keberadaannya: dari tujuh temuan pada sesi audit jimat, tiga bisa ditemukan
#  dengan satu grep -- mojibake di teks UI, tur screenshot yang dipanggil dua kali, dan
#  nol pemanggilan grab_focus(). Ketiganya STATIS, dan framework sama sekali tidak
#  memeriksanya: ia hanya melihat apa yang berhasil dirender. Akibatnya tiga temuan itu
#  bergantung pada ada-tidaknya seseorang yang kebetulan curiga dan mengetik grep.
#
#  Semua pemeriksaan di sini deterministik, tidak menjalankan Godot, dan selesai dalam
#  hitungan detik. Yang tidak bisa dipastikan secara statis TIDAK dipaksakan jadi error --
#  pemeriksa yang berisik akan dimatikan orang, dan pemeriksa yang mati tidak menemukan apa pun.
# =============================================================================

param(
    [string]   $ProjectPath = "",
    [string]   $OutputPath  = "",
    [string[]] $ExcludeDirs = @(),   # pola tambahan, dicocokkan terhadap path relatif
    [switch]   $IncludeAddons,       # ikut periksa addons/ (plugin pihak ketiga)
    [switch]   $Strict,              # jadikan warning ikut menggagalkan
    [switch]   $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param($m) if (-not $Quiet) { Write-Host "[gdoc] $m"      -ForegroundColor Cyan   } }
function Write-Ok   { param($m) if (-not $Quiet) { Write-Host "[gdoc] OK  $m"  -ForegroundColor Green  } }
function Write-Warn { param($m) if (-not $Quiet) { Write-Host "[gdoc] WARN $m" -ForegroundColor Yellow } }
function Write-Bad  { param($m) if (-not $Quiet) { Write-Host "[gdoc] FAIL $m" -ForegroundColor Red    } }
function Write-Info { param($m) if (-not $Quiet) { Write-Host "[gdoc] ..  $m"  -ForegroundColor Gray   } }

if ($ProjectPath -eq "") { $ProjectPath = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $ProjectPath)) { Write-Bad "ProjectPath tidak ada: $ProjectPath"; exit 1 }
$projectGodotFile = Join-Path $ProjectPath "project.godot"
if (-not (Test-Path -LiteralPath $projectGodotFile)) {
    Write-Bad "Bukan project Godot (project.godot tidak ditemukan): $ProjectPath"
    exit 1
}

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string] $Id, [string] $Severity, [string] $Message, [string] $File = "", [int] $Line = 0, [string] $Fix = "")
    $findings.Add([ordered]@{
        id = $Id; severity = $Severity; message = $Message
        file = $File; line = $Line; fix = $Fix
    })
}

# File template framework yang di-vendor ke game. Dikecualikan dari pemeriksaan yang
# menilai KODE GAME -- kalau tidak, komentar dan string di dalam template ikut terhitung
# dan hasilnya terbalik. Contoh nyata: grab_focus() hanya muncul di ScenarioRunner
# (di dalam pesan peringatan), sehingga pemeriksaan naif menyimpulkan game sudah memakainya.
$vendored = @("ErrorTracker.gd", "GameStateWriter.gd", "ScenarioRunner.gd",
              "AnomalyDetector.gd", "InputRecorder.gd", "RecordingConverter.gd")

# Direktori yang bukan kode game aktif. Tanpa pengecualian ini, temuan pertama yang muncul
# adalah salinan cadangan buatan pengguna sendiri -- terdeteksi saat menguji tool ini, yang
# dengan patuh melaporkan mojibake di folder _backup-... milik saya. Pemeriksa yang menuduh
# arsip akan cepat kehilangan kepercayaan, dan pemeriksa yang tidak dipercaya akan dimatikan.
$skipPatterns = @(
    '(^|\\)\.',            # .godot, .git, .import, dan direktori tersembunyi lain
    '(^|\\)_?backup',      # _backup-2026..., backup/
    '(^|\\)_?old(\\|$)',
    '(^|\\)(build|export|dist)(\\|$)'
)
if (-not $IncludeAddons) { $skipPatterns += '(^|\\)addons(\\|$)' }
foreach ($p in $ExcludeDirs) { $skipPatterns += [regex]::Escape($p) }

$allGd = @(Get-ChildItem -LiteralPath $ProjectPath -Filter "*.gd" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($ProjectPath.Length).TrimStart("\")
        $keep = $true
        foreach ($pat in $skipPatterns) { if ($rel -match $pat) { $keep = $false; break } }
        $keep
    })
$gameGd = @($allGd | Where-Object { $vendored -notcontains $_.Name })

Write-Step "Project : $ProjectPath"
Write-Step "Script  : $($allGd.Count) .gd ($($gameGd.Count) milik game, $($allGd.Count - $gameGd.Count) vendored)"

# ── C1: mojibake (UTF-8 yang pernah dibaca sebagai CP1252 lalu disimpan ulang) ──
# Deteksi memakai uji keterbalikan, bukan daftar urutan karakter: encode CP1252 ketat lalu
# decode UTF-8 ketat. Kalau KEDUANYA berhasil dan hasilnya punya lebih sedikit karakter
# non-ASCII, file itu pasti ter-encode ganda. Teks UTF-8 yang benar akan gagal di langkah
# decode (mis. em-dash asli jadi byte 0x97 yang bukan UTF-8 valid), jadi false positive
# praktis nol -- dan angka "berkurang berapa" sekaligus jadi ukuran kerusakannya.
$cp1252 = [System.Text.Encoding]::GetEncoding(1252,
    [System.Text.EncoderFallback]::ExceptionFallback,
    [System.Text.DecoderFallback]::ExceptionFallback)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

foreach ($f in $allGd) {
    $raw = [System.IO.File]::ReadAllBytes($f.FullName)
    $off = if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { 3 } else { 0 }
    $text = $null
    try { $text = $utf8Strict.GetString($raw, $off, $raw.Length - $off) } catch { continue }
    if ($text -notmatch "[^\x00-\x7F]") { continue }
    $fixed = $null
    try { $fixed = $utf8Strict.GetString($cp1252.GetBytes($text)) } catch { continue }
    if ($fixed -ceq $text) { continue }
    $naBefore = ([regex]::Matches($text,  "[^\x00-\x7F]")).Count
    $naAfter  = ([regex]::Matches($fixed, "[^\x00-\x7F]")).Count
    if ($naAfter -ge $naBefore) { continue }

    $rel = $f.FullName.Substring($ProjectPath.Length).TrimStart("\")
    # Apakah kerusakan sampai ke layar, atau cuma di komentar?
    $lines = $text -split "`n"
    $uiHit = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '"' -and $lines[$i] -match "[ÂÃâ]" -and $lines[$i] -notmatch '^\s*#') { $uiHit++ }
    }
    $sev = if ($uiHit -gt 0) { "error" } else { "warning" }
    $msg = "Teks ter-encode ganda (mojibake): $naBefore karakter non-ASCII rusak, $uiHit di antaranya berada di baris yang mengandung string"
    Add-Finding -Id "mojibake" -Severity $sev -Message $msg -File $rel `
        -Fix "Baca file sebagai UTF-8, encode ke CP1252, decode lagi sebagai UTF-8. Verifikasi dengan menerapkan ulang kerusakan pada hasilnya -- harus menghasilkan isi lama persis."
}

# ── C2: game memanggil _shot_tour sendiri ──────────────────────────────────────
# Kontraknya: ErrorTracker._shot_quit_watchdog adalah SATU-SATUNYA pemanggil. Kalau game
# juga memanggilnya, dua tur berjalan bersamaan pada UI dan state yang sama dan screenshot
# tersimpan dengan nama layar yang SALAH. Kerusakannya diam: jumlah file tetap benar dan
# coverage tetap 100%, jadi tidak ada pemeriksaan runtime yang bisa melihatnya.
foreach ($f in $gameGd) {
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
        $i++
        if ($line -match '^\s*#') { continue }
        if ($line -match 'func\s+_shot_tour') { continue }
        if ($line -match '_shot_tour\s*\.\s*call_deferred|call_deferred\s*\(\s*"_shot_tour"|(?<![\w.])_shot_tour\s*\(') {
            $rel = $f.FullName.Substring($ProjectPath.Length).TrimStart("\")
            Add-Finding -Id "shot_tour_dipanggil_game" -Severity "error" -File $rel -Line $i `
                -Message "Game memanggil _shot_tour() sendiri; ErrorTracker juga memanggilnya, sehingga dua tur screenshot berjalan bersamaan" `
                -Fix "Hapus pemanggilan ini. ErrorTracker._shot_quit_watchdog yang memilikinya."
        }
    }
}

# ── C3: membangun tombol tapi tidak pernah memanggil grab_focus() ──────────────
# Godot TIDAK memfokuskan Control mana pun secara otomatis. Tanpa grab_focus(), pemain
# keyboard/gamepad menekan Enter di layar pertama dan tidak terjadi apa-apa -- dan semua
# scenario berbasis action ui_* ikut mati tanpa jejak.
$buttonEvidence = @($gameGd | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'Button\.new\(\)|menu_button\(|\.pressed\.connect'
})
$focusEvidence = @($gameGd | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'grab_focus'
})
if ($buttonEvidence.Count -gt 0 -and $focusEvidence.Count -eq 0) {
    Add-Finding -Id "tanpa_grab_focus" -Severity "warning" `
        -Message "Project membangun tombol di $($buttonEvidence.Count) file tetapi tidak pernah memanggil grab_focus(). Navigasi keyboard/gamepad kemungkinan besar mati sejak layar pertama" `
        -Fix "Panggil grab_focus() pada kontrol pertama tiap layar, mis. di akhir fungsi yang membangun menu."
}

# ── C4: cabang --scenario yang berhenti sebelum layar dibangun ─────────────────
# Ini cacat termahal yang ditemukan pada jimat: cabang --scenario membangun Control kosong
# lalu `return`, sehingga SEMUA scenario berjalan melawan layar kosong dan tetap melaporkan
# PASS. Statis hanya bisa mencurigai, tidak memastikan -- karena itu warning, dan pesannya
# meminta verifikasi, bukan menuduh. Gerbang liveness yang memastikannya saat runtime.
foreach ($f in $gameGd) {
    $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '--scenario') { continue }
        if ($lines[$i] -match '^\s*#') { continue }
        $limit = [math]::Min($i + 25, $lines.Count - 1)
        for ($j = $i + 1; $j -le $limit; $j++) {
            if ($lines[$j] -match '^\s*return\s*$') {
                $rel = $f.FullName.Substring($ProjectPath.Length).TrimStart("\")
                Add-Finding -Id "scenario_berhenti_dini" -Severity "warning" -File $rel -Line ($j + 1) `
                    -Message 'Cabang --scenario tampak berakhir dengan "return" sebelum layar dibangun. Pastikan game benar-benar sampai ke layar pertamanya saat dijalankan dengan --scenario' `
                    -Fix "Biarkan cabang --scenario melanjutkan ke pembangunan UI dan navigasi layar awal, supaya jalur yang diuji sama dengan jalur yang dimainkan."
                break
            }
            if ($lines[$j] -match '^\s*(func|class)\s') { break }
        }
    }
}

# ── C5: autoload framework terpasang? ─────────────────────────────────────────
$pg = Get-Content -LiteralPath $projectGodotFile -Raw -Encoding UTF8
foreach ($al in @(
    @{ Name = "ErrorTracker";    Sev = "error";   Why = "tanpa ini flag --shot dan --scenario tidak pernah ter-handle" },
    @{ Name = "GameStateWriter"; Sev = "warning"; Why = "tanpa ini assert_state hanya melihat state fallback generik" }
)) {
    if ($pg -notmatch [regex]::Escape($al.Name)) {
        Add-Finding -Id "autoload_hilang" -Severity $al.Sev -File "project.godot" `
            -Message "Autoload $($al.Name) tidak terdaftar -- $($al.Why)" `
            -Fix "Jalankan setup.ps1 -InitProject, atau tambahkan sendiri di bagian [autoload]."
    }
}

# ── C6: penyedia state milik game ─────────────────────────────────────────────
$stateProvider = @($gameGd | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '_get_game_state|_write_game_state'
})
if ($stateProvider.Count -eq 0) {
    Add-Finding -Id "tanpa_penyedia_state" -Severity "warning" `
        -Message "Tidak ada _get_game_state() maupun _write_game_state() di kode game. assert_state dan invariant hanya akan melihat field fallback generik" `
        -Fix "Implementasikan _get_game_state() -> Dictionary di node utama, berisi field yang benar-benar menentukan kemajuan permainan."
}

# ── C7: invariant belum dipakai ───────────────────────────────────────────────
$scenDir = Join-Path $ProjectPath "scenarios"
if (Test-Path -LiteralPath $scenDir) {
    if (-not (Test-Path -LiteralPath (Join-Path $scenDir "invariants.json"))) {
        Add-Finding -Id "tanpa_invariant" -Severity "info" `
            -Message "scenarios/ ada tetapi tanpa invariants.json. Invariant adalah satu-satunya pemeriksaan yang berjalan di SETIAP langkah, dan tanpa itu bug 'progres melompat' tidak akan pernah terdeteksi" `
            -Fix "Salin scenarios-templates/invariants.json ke scenarios/ lalu sesuaikan field-nya."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $scenDir "visual-claims.json"))) {
        Add-Finding -Id "tanpa_klaim_visual" -Severity "info" `
            -Message "scenarios/ ada tetapi tanpa visual-claims.json. Tanpa itu tidak ada penilaian visual yang tersimpan lintas sesi" `
            -Fix "Salin scenarios-templates/visual-claims.json ke scenarios/ lalu sesuaikan."
    }
}

# ── C8: template vendored menyimpang dari framework ───────────────────────────
$fwTemplates = Join-Path $env:USERPROFILE ".config\kilo\godot-templates"
if (Test-Path -LiteralPath $fwTemplates) {
    foreach ($f in ($allGd | Where-Object { $vendored -contains $_.Name })) {
        $src = Join-Path $fwTemplates $f.Name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $h1 = (Get-FileHash -LiteralPath $src -Algorithm MD5).Hash
        $h2 = (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash
        if ($h1 -ne $h2) {
            $rel = $f.FullName.Substring($ProjectPath.Length).TrimStart("\")
            Add-Finding -Id "template_menyimpang" -Severity "warning" -File $rel `
                -Message "Salinan $($f.Name) di game berbeda dari versi framework. Perbaikan framework terbaru tidak berlaku di sini" `
                -Fix "Salin ulang dari $fwTemplates, atau jalankan sync yang kamu pakai untuk vendoring."
        }
    }
}

# ── C9: class_name ganda di dalam satu project ────────────────────────────────
# Godot menolak memuat DUA script yang mendaftarkan class_name sama, dan yang gagal bukan
# hanya salinannya -- yang asli ikut mati dengan "Class X hides a global script class".
# Konsekuensinya diam dan jauh: script yang tidak bisa dimuat membuat layar yang memakainya
# tidak pernah terbangun, dan tur screenshot berhenti di tengah tanpa pesan yang menyebut
# sebabnya.
#
# Terjadi betulan di sesi ini: folder cadangan bertanggal ditaruh DI DALAM project jimat,
# berisi salinan ui_theme.gd dan battle_screen.gd. Sejak saat itu tur berhenti di 14 dari
# 23 layar selama berjam-jam, dan tidak ada satu pun pemeriksaan yang menyebut penyebabnya.
#
# Pemindaian di sini SENGAJA tidak memakai $skipPatterns. Daftar itu ada untuk menekan
# kebisingan doctor, sedangkan Godot tidak mengenalnya -- dan justru di folder yang doctor
# lewati itulah duplikat biasanya bersembunyi. Yang dipakai adalah aturan Godot sendiri:
# direktori berawalan titik diabaikan, direktori yang memuat .gdignore diabaikan.
$gdIgnored = @(Get-ChildItem -LiteralPath $ProjectPath -Filter ".gdignore" -Recurse -File -Force -ErrorAction SilentlyContinue |
               ForEach-Object { $_.DirectoryName })
$godotVisible = @(Get-ChildItem -LiteralPath $ProjectPath -Filter "*.gd" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($ProjectPath.Length).TrimStart("\")
        if ($rel -match '(^|\\)\.') { return $false }          # direktori/berkas berawalan titik
        foreach ($ig in $gdIgnored) {
            if ($_.FullName.StartsWith($ig, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    })

$classDecls = @{}
foreach ($f in $godotVisible) {
    foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*class_name\s+([A-Za-z_][A-Za-z0-9_]*)') {
            $cn = $Matches[1]
            if (-not $classDecls.ContainsKey($cn)) { $classDecls[$cn] = @() }
            $classDecls[$cn] += $f.FullName.Substring($ProjectPath.Length).TrimStart("\")
            break   # class_name hanya boleh sekali per file
        }
    }
}
foreach ($cn in ($classDecls.Keys | Sort-Object)) {
    $where = @($classDecls[$cn])
    if ($where.Count -le 1) { continue }
    Add-Finding -Id "class_name_ganda" -Severity "error" -File $where[0] `
        -Message "class_name '$cn' dideklarasikan di $($where.Count) berkas: $($where -join ', '). Godot menolak memuat keduanya -- yang ASLI ikut mati, dan layar yang memakainya tidak pernah terbangun" `
        -Fix "Pindahkan salinan/cadangan ke LUAR direktori project, atau taruh berkas .gdignore di direktorinya supaya Godot melewatinya sama sekali."
}

# ── Laporan ───────────────────────────────────────────────────────────────────
$nErr  = @($findings | Where-Object { $_.severity -eq "error" }).Count
$nWarn = @($findings | Where-Object { $_.severity -eq "warning" }).Count
$nInfo = @($findings | Where-Object { $_.severity -eq "info" }).Count

if (-not $Quiet) {
    Write-Host ""
    foreach ($sev in @("error", "warning", "info")) {
        foreach ($f in ($findings | Where-Object { $_.severity -eq $sev })) {
            $loc = if ($f.file -ne "") { " [$($f.file)$(if ($f.line -gt 0) { ":$($f.line)" })]" } else { "" }
            switch ($sev) {
                "error"   { Write-Bad  "$($f.message)$loc" }
                "warning" { Write-Warn "$($f.message)$loc" }
                default   { Write-Info "$($f.message)$loc" }
            }
            if ($f.fix -ne "") { Write-Host "         -> $($f.fix)" -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
    Write-Step "Hasil: $nErr error, $nWarn warning, $nInfo info"
}

if ($OutputPath -eq "") { $OutputPath = Join-Path $ProjectPath "game-doctor-report.json" }
[ordered]@{
    schema_version = "1.0"
    generated_at   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    project        = $ProjectPath
    summary        = [ordered]@{ error = $nErr; warning = $nWarn; info = $nInfo }
    findings       = @($findings)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Step "Laporan: $OutputPath"

if ($nErr -gt 0) { exit 1 }
if ($Strict -and $nWarn -gt 0) { exit 1 }
Write-Ok "Tidak ada masalah yang menggagalkan."
exit 0
