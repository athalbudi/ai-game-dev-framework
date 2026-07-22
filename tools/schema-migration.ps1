<#
.SYNOPSIS
    Schema migration handler untuk shots-manifest.json dan file output framework lainnya.
    Deteksi format lama dan migrate ke schema_version terbaru secara otomatis.

.DESCRIPTION
    Framework menggunakan schema_version untuk tracking format manifest.
    Ketika format berubah, file lama perlu di-migrate agar consumer tetap bisa membacanya.

    Schema yang dikelola:
      shots-manifest.json  : 1.0 -> 1.1
      coverage-history.json entries : 1.0 (stable, tidak perlu migration saat ini)
      scenario_result.json : 1.0 (stable, tidak perlu migration saat ini)

    Perubahan antar schema:
      1.0 -> 1.1:
        + schema_version field ditambahkan
        + coverage field ditambahkan (sebelumnya tidak ada)
        + project_path field ditambahkan
        + screenshots[].size_kb ditambahkan
        + elapsed_sec ditambahkan
        + baseline_age_days ditambahkan

.PARAMETER ManifestPath
    Path ke shots-manifest.json yang akan di-migrate. Jika kosong, cari otomatis.

.PARAMETER ShotsDir
    Path ke folder shots. Digunakan untuk auto-detect manifest jika ManifestPath kosong.

.PARAMETER DryRun
    Jika di-set, tampilkan perubahan yang akan dilakukan tanpa menyimpan ke disk.

.PARAMETER Backup
    Jika di-set, buat backup file sebelum migration (default: true).

.EXAMPLE
    # Migrate manifest di folder shots tertentu
    & "$env:USERPROFILE\.config\kilo\tools\schema-migration.ps1" -ShotsDir "C:\dev\mygame\shots"

.EXAMPLE
    # Dry run -- lihat apa yang akan berubah
    & "$env:USERPROFILE\.config\kilo\tools\schema-migration.ps1" -ShotsDir "C:\dev\mygame\shots" -DryRun

.EXAMPLE
    # Migrate file tertentu tanpa backup
    & "$env:USERPROFILE\.config\kilo\tools\schema-migration.ps1" -ManifestPath "C:\dev\mygame\shots\shots-manifest.json" -Backup:$false
#>

[CmdletBinding()]
param(
    [string] $ManifestPath = "",
    [string] $ShotsDir     = "",
    [switch] $DryRun,
    [bool]   $Backup       = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ──────────────────────────────────────────────────────────────────
$CURRENT_SCHEMA = "1.1"

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Mig  { param($msg) Write-Host "[migrate] $msg"        -ForegroundColor Cyan   }
function Write-Ok   { param($msg) Write-Host "[migrate] OK   $msg"   -ForegroundColor Green  }
function Write-Warn { param($msg) Write-Host "[migrate] WARN $msg"   -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "[migrate] FAIL $msg"   -ForegroundColor Red; exit 1 }
function Write-Dry  { param($msg) Write-Host "[migrate] DRY  $msg"   -ForegroundColor Magenta }

# ── Resolve manifest path ──────────────────────────────────────────────────────
function Resolve-ManifestPath {
    param([string]$shotsDir, [string]$manifestPath)

    if ($manifestPath -ne "") {
        if (Test-Path -LiteralPath $manifestPath) { return $manifestPath }
        Write-Fail "ManifestPath tidak ditemukan: $manifestPath"
    }

    if ($shotsDir -ne "") {
        $p = Join-Path $shotsDir "shots-manifest.json"
        if (Test-Path -LiteralPath $p) { return $p }
        Write-Fail "shots-manifest.json tidak ditemukan di: $shotsDir"
    }

    # Auto-detect dari working directory
    $candidates = @(
        (Join-Path (Get-Location).Path "shots\shots-manifest.json"),
        (Join-Path (Get-Location).Path "shots-manifest.json")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            Write-Mig "Auto-detected manifest: $c"
            return $c
        }
    }
    Write-Fail "shots-manifest.json tidak ditemukan. Gunakan -ShotsDir atau -ManifestPath."
}

# ── Read manifest ──────────────────────────────────────────────────────────────
function Read-Manifest {
    param([string]$path)
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    } catch {
        Write-Fail "Gagal membaca manifest: $_"
    }
}

# ── Detect schema version ──────────────────────────────────────────────────────
function Get-SchemaVersion {
    param($manifest)
    $sv = $manifest.PSObject.Properties["schema_version"]
    if ($sv -ne $null -and $sv.Value -ne $null) {
        return $sv.Value.ToString()
    }
    # Tidak ada schema_version = versi 1.0 (format awal)
    return "1.0"
}

# ── Migration: 1.0 -> 1.1 ─────────────────────────────────────────────────────
function Migrate-1_0-to-1_1 {
    param($manifest, [string]$manifestPath)

    Write-Mig "Migrasi 1.0 -> 1.1..."
    $changes = [System.Collections.Generic.List[string]]::new()

    # Field yang ditambahkan di 1.1
    $result = [ordered]@{}

    # schema_version -- tambahkan di urutan pertama
    $result["schema_version"] = "1.1"
    $changes.Add("+ schema_version = '1.1'")

    # Salin field yang sudah ada
    foreach ($prop in $manifest.PSObject.Properties) {
        if ($prop.Name -ne "schema_version") {
            $result[$prop.Name] = $prop.Value
        }
    }

    # Tambahkan field baru yang belum ada di 1.0
    if (-not $result.Contains("elapsed_sec")) {
        $result["elapsed_sec"] = $null
        $changes.Add("+ elapsed_sec = null (tidak tersedia di format lama)")
    }

    if (-not $result.Contains("project_path")) {
        # Coba infer dari shots_dir
        $shotsDir = if ($result.Contains("shots_dir")) { $result["shots_dir"] } else { "" }
        $inferredPath = if ($shotsDir -ne "") { Split-Path $shotsDir -Parent } else { $null }
        $result["project_path"] = $inferredPath
        $changes.Add("+ project_path = '$inferredPath' (inferred dari shots_dir)")
    }

    if (-not $result.Contains("coverage")) {
        # Buat coverage minimal dari screenshot yang ada
        $screenshots = if ($result.Contains("screenshots")) { @($result["screenshots"]) } else { @() }
        $screenNames = @($screenshots | ForEach-Object {
            if ($_ -and $_.PSObject.Properties["file"]) {
                $_.file -replace "^\d+_", "" -replace "\.png$", "" -replace "_", " "
            }
        } | Where-Object { $_ })

        $result["coverage"] = [ordered]@{
            known_screens  = $screenNames.Count
            covered        = @($screenNames | ForEach-Object { $_.ToLower() })
            uncovered      = @()
            coverage_pct   = if ($screenNames.Count -gt 0) { 100 } else { 0 }
            note           = "Migrated from schema 1.0 -- coverage inferred from PNG filenames"
        }
        $changes.Add("+ coverage (inferred dari $($screenNames.Count) screenshots)")
    }

    if (-not $result.Contains("baseline_age_days")) {
        $result["baseline_age_days"] = $null
        $changes.Add("+ baseline_age_days = null (tidak tersedia di format lama)")
    }

    # Update screenshots: tambahkan size_kb jika belum ada
    if ($result.Contains("screenshots") -and $result["screenshots"]) {
        $shotsDir = if ($result.Contains("shots_dir")) { $result["shots_dir"] } else { "" }
        $updatedScreenshots = @($result["screenshots"]) | ForEach-Object {
            if (-not $_ -or -not $_.PSObject.Properties["file"]) { return $_ }
            $ss = [ordered]@{}
            foreach ($p in $_.PSObject.Properties) { $ss[$p.Name] = $p.Value }
            if (-not $ss.Contains("size_kb")) {
                # Guard: shots_dir di manifest lama mungkin menunjuk drive yang tidak ada.
                # Bungkus Join-Path dalam try agar DriveNotFoundException tidak crash migrasi.
                $filePath = ""
                if ($shotsDir -ne "") {
                    try { $filePath = Join-Path $shotsDir $ss["file"] } catch { $filePath = "" }
                }
                $sizeKb = if ($filePath -ne "" -and (Test-Path -LiteralPath $filePath -ErrorAction SilentlyContinue)) {
                    [math]::Round((Get-Item -LiteralPath $filePath).Length / 1024, 1)
                } else { $null }
                $ss["size_kb"] = $sizeKb
            }
            [PSCustomObject]$ss
        }
        $result["screenshots"] = $updatedScreenshots
        $changes.Add("+ screenshots[].size_kb (ditambahkan per file)")
    }

    return @{ manifest = [PSCustomObject]$result; changes = $changes }
}

# ── Main migration function ────────────────────────────────────────────────────
function Invoke-Migration {
    param([string]$manifestPath)

    $manifest = Read-Manifest -path $manifestPath
    $version  = Get-SchemaVersion -manifest $manifest

    Write-Mig "File: $manifestPath"
    Write-Mig "Schema saat ini: $version"
    Write-Mig "Target schema  : $CURRENT_SCHEMA"

    if ($version -eq $CURRENT_SCHEMA) {
        Write-Ok "Sudah schema terbaru ($CURRENT_SCHEMA) -- tidak perlu migration"
        return @{ status = "up_to_date"; changes = @() }
    }

    # Jalankan migration chain
    $migratedManifest = $manifest
    $allChanges = [System.Collections.Generic.List[string]]::new()
    $currentVersion = $version

    # 1.0 -> 1.1
    if ($currentVersion -eq "1.0") {
        $result = Migrate-1_0-to-1_1 -manifest $migratedManifest -manifestPath $manifestPath
        $migratedManifest = $result.manifest
        foreach ($c in $result.changes) { $allChanges.Add($c) }
        $currentVersion = "1.1"
    }

    # Future migrations: tambahkan di sini
    # if ($currentVersion -eq "1.1") {
    #     $result = Migrate-1_1-to-1_2 -manifest $migratedManifest ...
    # }

    if ($DryRun) {
        Write-Dry "DRY RUN -- perubahan yang akan dilakukan:"
        foreach ($c in $allChanges) { Write-Dry "  $c" }
        Write-Dry "File TIDAK disimpan (dry run mode)"
        return @{ status = "dry_run"; changes = @($allChanges) }
    }

    # Backup jika diminta
    if ($Backup) {
        $backupPath = $manifestPath -replace "\.json$", "_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        Copy-Item -LiteralPath $manifestPath -Destination $backupPath -Force
        Write-Ok "Backup: $backupPath"
    }

    # Tulis hasil migration
    $json = $migratedManifest | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $manifestPath -Value $json -Encoding UTF8
    Write-Ok "Migration selesai: $manifestPath"
    Write-Ok "Schema: $version -> $currentVersion"

    foreach ($c in $allChanges) { Write-Mig "  $c" }

    return @{ status = "migrated"; from = $version; to = $currentVersion; changes = @($allChanges) }
}

# ── Scan dan migrate semua manifest di ShotsDir ───────────────────────────────
function Invoke-BulkMigration {
    param([string]$shotsDir)

    $manifests = @(
        (Join-Path $shotsDir "shots-manifest.json"),
        # Cek subfolder baseline
        (Join-Path $shotsDir "baseline\baseline-manifest.json")
    )

    $results = @()
    foreach ($m in $manifests) {
        if (Test-Path -LiteralPath $m) {
            Write-Mig ""
            $r = Invoke-Migration -manifestPath $m
            $results += @{ path = $m; result = $r }
        }
    }
    return $results
}

# ── Entry point ────────────────────────────────────────────────────────────────
Write-Mig "Schema Migration Handler -- AI-Assisted Game Development Framework"
Write-Mig "Target schema: $CURRENT_SCHEMA"
if ($DryRun) { Write-Mig "Mode: DRY RUN" }

if ($ShotsDir -ne "" -and $ManifestPath -eq "") {
    # Bulk migration untuk semua manifest di ShotsDir
    Invoke-BulkMigration -shotsDir $ShotsDir
} else {
    $path = Resolve-ManifestPath -shotsDir $ShotsDir -manifestPath $ManifestPath
    Invoke-Migration -manifestPath $path
}
