---
description: Loop QA autonomous — Observe, Detect, Hypothesize, Generate, Run, Analyze, Iterate, Report. AI mengamati anomali, menyusun hipotesis, membuat scenario investigasi, dan melakukan iterasi mandiri.
---

Kamu menjalankan Autonomous QA Loop untuk AI-assisted game development framework.
Framework ini universal — tidak bergantung pada game tertentu, genre tertentu, atau struktur folder spesifik.

Loop yang dijalankan:
```
OBSERVE → DETECT → HYPOTHESIZE → GENERATE → RUN → ANALYZE → ITERATE → REPORT
```

ProjectPath default: direktori kerja saat ini (atau tanya user jika ambigu)
ShotsDir: baca dari shots-manifest.json, atau resolve otomatis dari project.godot

---

## Subcommands

### /autonomous-qa run
Jalankan loop QA autonomous penuh.

Langkah:
1. Resolve ProjectPath dari working directory atau tanya user
2. Resolve ShotsDir dari shots-manifest.json
3. Jalankan `autonomous-qa.ps1`:
   ```powershell
   & "$env:USERPROFILE\.config\kilo\tools\autonomous-qa.ps1" -ProjectPath "<ProjectPath>"
   ```
4. Baca laporan output: `<ShotsDir>\autonomous-qa\autonomous-qa-report_<ts>.json`
5. Baca anomali yang ditemukan dan diinvestigasi
6. Tampilkan ringkasan:
   - Total anomali ditemukan
   - Anomali yang berhasil diinvestigasi
   - Anomali yang masih unresolved
   - Scenario yang dibuat dan hasilnya
7. Untuk setiap unresolved anomali, berikan rekomendasi tindak lanjut konkret

### /autonomous-qa run --skip-harness
Jalankan loop menggunakan manifest yang sudah ada (skip fase OBSERVE).

Berguna ketika:
- Harness sudah dijalankan sebelumnya di sesi yang sama
- Ingin re-analyze hasil run sebelumnya
- Godot tidak tersedia tapi manifest sudah ada

```powershell
& "$env:USERPROFILE\.config\kilo\tools\autonomous-qa.ps1" -ProjectPath "<ProjectPath>" -SkipInitialHarness
```

### /autonomous-qa run --iterations <n>
Jalankan loop dengan jumlah iterasi tertentu.

Default: 3. Kurangi untuk kasus sederhana, tambah untuk investigasi mendalam.

```powershell
& "$env:USERPROFILE\.config\kilo\tools\autonomous-qa.ps1" -ProjectPath "<ProjectPath>" -MaxIterations <n>
```

### /autonomous-qa status
Tampilkan status loop terakhir yang dijalankan.

Langkah:
1. Cari file laporan terbaru di `<ShotsDir>\autonomous-qa\autonomous-qa-report_*.json`
2. Tampilkan ringkasan: iterasi, anomali, status investigasi
3. Tampilkan unresolved anomali jika ada

### /autonomous-qa report
Baca dan tampilkan laporan autonomous QA terakhir secara lengkap.

Langkah:
1. Cari file laporan terbaru di `<ShotsDir>\autonomous-qa\`
2. Tampilkan semua finding dengan format terstruktur:
   - ❌ = critical
   - ⚠️ = warning
   - ℹ️ = info
3. Untuk setiap finding, tampilkan:
   - Deskripsi anomali
   - Evidence (data aktual)
   - Tindakan yang disarankan
4. Tampilkan scenario yang dibuat di setiap iterasi
5. Berikan kesimpulan dan prioritas perbaikan

### /autonomous-qa investigate <deskripsi_masalah>
Buat scenario investigasi untuk masalah spesifik yang disebutkan user.

Langkah:
1. Baca shots-manifest.json untuk konteks game state terbaru
2. Analisis deskripsi masalah dari user
3. Susun hipotesis: apa yang mungkin menyebabkan masalah tersebut
4. Buat scenario JSON yang menguji hipotesis:
   - Gunakan step types yang relevan (assert_state, screenshot, wait_condition, dll)
   - Sertakan write_state dan screenshot di titik-titik kritis
   - Sertakan seed_override untuk reproduksi deterministik
5. Simpan ke `<ProjectPath>/scenarios/investigate_<nama>.json`
6. Tampilkan scenario yang dibuat dan cara menjalankannya: `/scenario run investigate_<nama>`

---

## Anomali yang Dideteksi Otomatis

Autonomous QA loop mendeteksi anomali dari data yang tersedia tanpa membaca screenshot:

| Kategori | Anomali | Severity |
|---|---|---|
| Coverage | Fase prototype/developing — belum ada screenshot atau game_state | Warning/Info |
| Visual | Screenshot stale >24 jam | Warning/Critical |
| Visual | Visual regression dari diff-report | Critical |
| Visual | Screenshot hilang dari run terbaru | Critical |
| State | `hp=0` tapi `is_alive=true` — health bar mismatch | Critical |
| State | `shots_taken` vs `png_count` mismatch | Warning |
| State | Resource negatif (coins, gold, dll) | Warning |
| Scenario | Step fail dari scenario_result.json | Critical |
| Scenario | Banyak step di-skip | Warning |
| Performance | Shot tour > 60 detik | Warning |
| Performance | assert_fps fail | Critical |
| Coverage | Seed tidak tersedia di game_state | Info |

## Scenario yang Dibuat Otomatis

Setiap iterasi, loop membuat scenario investigation JSON berisi:
- `seed_override` untuk reproduksi deterministik
- `screenshot` untuk anomali visual
- `write_state` + `assert_state` untuk anomali state
- `log` steps untuk traceability

Scenario disimpan di `<ShotsDir>/autonomous-qa/scenario_iter<n>_<ts>.json`
dan bisa dijalankan ulang dengan `/scenario run` untuk reproduksi.

## Prinsip Loop

Loop berhenti otomatis ketika:
- Tidak ada anomali critical baru setelah iterasi pertama
- Semua anomali yang terdeteksi sudah diinvestigasi
- MaxIterations tercapai

Loop tidak berhenti karena:
- Ada anomali warning yang belum diinvestigasi (diteruskan ke laporan saja)
- Scenario gagal dijalankan (dicatat, loop lanjut)
- Godot tidak tersedia (skip fase RUN, deteksi tetap berjalan)

---

## Argumen

$ARGUMENTS
