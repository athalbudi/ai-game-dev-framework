# AGENTS.md — Instruksi AI Global

Berlaku di semua project. Project-level AGENTS.md dapat meng-override bagian ini.

---

## Aturan Proaktif: Analisis Project

Tentukan skenario yang paling sesuai dan ikuti urutannya.

### Skenario 1 — "Analisis update" / "apa yang baru berubah?"

1. Cari changelog terbaru dengan urutan prioritas:
   - `git log --oneline -20` jika project adalah git repo
   - File changelog manual: cari `CHANGELOG.md`, `CHANGES.md`, atau file catatan di `docs/`
2. Jalankan validasi visual jika ada komponen tampilan yang berubah
3. Baca docs yang relevan dengan perubahan tersebut
4. Baca kode spesifik hanya jika ada temuan yang perlu diverifikasi implementasinya

### Skenario 2 — "Analisis kondisi" / "review" / "evaluasi" / "cek kondisi"

1. Jalankan validasi visual terlebih dahulu jika project punya UI/tampilan
2. Baca dokumentasi relevan sebagai konteks
3. Gabungkan temuan visual + dokumentasi dalam laporan

### Skenario 3 — Bug visual / laporan masalah tampilan spesifik

1. Jalankan validasi visual untuk mereproduksi bug
2. Baca kode spesifik yang terkait
3. Baca docs untuk konfirmasi intended behavior

---

## Aturan Proaktif: Validasi Visual

### Auto-discover harness screenshot

Sebelum validasi visual, cek ketersediaan harness di project dengan urutan:

1. Cek `.kilo/command/` — ada command screenshot? (contoh: `/shot`, `/analisis-shot`, `/screenshot`)
2. Cek `.kilo/agent/` — ada agent visual QA? (contoh: `visual-qa`, `visual-qa-web`)
3. Cek kode project — ada flag atau script screenshot? (contoh: `--shot`, `--screenshot`)
4. Cek `package.json` — ada script screenshot? (contoh: `playwright`, `cypress`, `screenshot`)

Jika harness tersedia, **jalankan harness terlebih dahulu** sebelum membaca screenshot.
Jika tidak ada harness, gunakan tool screenshot yang tersedia (Playwright, Cypress, dll).

### Wajib delegasi ke agent visual QA

Jika project punya agent visual QA (contoh: `visual-qa`, `visual-qa-web` di `.kilo/agent/`),
**JANGAN lakukan analisis visual sendiri** — delegasikan seluruhnya ke agent tersebut via `task` tool.

Main agent TIDAK boleh membaca file PNG sendiri untuk tujuan analisis visual. Alasannya:
- Agent visual QA punya prosedur batch yang terkontrol (maks 6 gambar per panggilan)
- Agent visual QA menggunakan `filesystem_read_media_file` yang benar, bukan `Read`
- Agent visual QA membaca semua gambar terlebih dahulu sebelum menulis analisis
- Main agent membaca PNG lewat `Read` menghasilkan attachment yang tidak selalu ter-deliver ke model,
  sehingga analisis visual yang dihasilkan main agent tidak bisa dipertanggungjawabkan

Contoh delegasi yang benar:
```
task(visual-qa): Jalankan harness screenshot dan analisis semua layar game untuk update terbaru.
Laporkan temuan visual lengkap dengan format standar (✅ ⚠️ ❌).
```

### Fallback jika validasi visual gagal

- Laporkan ke user secara eksplisit bahwa validasi visual tidak bisa dijalankan
- Gunakan screenshot lama di disk jika ada, dengan catatan eksplisit bahwa ini bukan state terkini
- Jangan diam-diam skip atau pakai data lama tanpa memberitahu user

### Kapan tidak perlu validasi visual

- Perubahan logika murni (formula, kalkulasi, balance, save/load)
- Refactor kode yang tidak menyentuh tampilan
- Fix bug non-visual (crash, error handling, perhitungan)

---

## Aturan Proaktif: Setelah Perubahan Kode

Ketika AI selesai mengimplementasikan perubahan yang menyentuh UI atau tampilan:
- Otomatis jalankan validasi visual — ini bagian dari definition of done
- Gunakan agent visual QA jika tersedia di project

---

## Aturan Umum

- Selalu baca file yang relevan sebelum membuat klaim tentang kode
- Jangan hardcode versi atau build number — baca dari sumber yang selalu update
- Jika ragu changelog ada di mana, cari dulu sebelum bertanya ke user
- Prioritaskan data aktual (screenshot terbaru, git log, file terbaru) di atas asumsi
- Jika ada dua sumber informasi yang konflik, sebutkan konfliknya ke user
