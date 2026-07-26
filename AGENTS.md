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

## Aturan Efisiensi Token

Biaya token bersifat kuadratik terhadap panjang sesi: request ke-i membawa i×g token history.
Dari data aktual proyek ini: g ≈ 21.400 token/exchange, 72 exchange = 56M token.
Memecah ke 4 sesi × 18 exchange menghemat ~3.8×; 8 sesi × 9 exchange menghemat ~7.5×.

**Temuan kritis:** Kuota harian (150M) menghitung token **mentah**, bukan token terdiskon.
Ini dibuktikan dari batas fisik: rata-rata 782K token/request dengan plafon 1M tidak konsisten
dengan adanya cache diskon 10× — itu akan melampaui plafon. Konsekuensinya: caching berguna
untuk biaya uang, tapi tidak mengurangi konsumsi kuota. Yang mengurangi kuota hanya lever
yang memperkecil token mentah: rotasi sesi dan baca range.

Estimasi penghematan kuota dari data aktual:

| Pola | Total token | % kuota harian |
|---|---:|---:|
| Sekarang (1 sesi × 72 exchange) | 56,3M | 38% |
| + rotasi sesi (4 × 18) | 14,5M | 10% |
| + baca range (g: 21K→8K) | 6,3M | 4% |

### Aturan wajib

1. **Rotasi sesi pada ~20 exchange.** Mulai sesi baru untuk topik atau task yang berbeda.
   Di awal sesi baru, baca `git log` dan file handoff — jangan andalkan memory sesi lama.

2. **Baca range, bukan file penuh.** File besar (contoh: `shot-harness.ps1` ~16K token,
   `run-and-analyze.ps1` ~12K, `test-pipeline.ps1` ~11K) masuk context dan dibayar ulang
   di setiap request sesudahnya. Grep dulu untuk menemukan lokasi, baca ±40 baris sekitarnya.

3. **Satu script menguji banyak hipotesis sekaligus.** Daripada 8 ronde tanya-jawab,
   tulis satu script yang menguji 4 hipotesis dan kembalikan output ringkas.
   Ini menyerang g (ukuran per exchange) dan n (jumlah exchange) sekaligus.

4. **Tulis handoff ke disk sebelum sesi berakhir.** Format standar:
   ```
   ## Handoff — <tanggal>
   Commit terakhir: <hash> <pesan>
   Status: <clean/ada perubahan>
   Selesai: <apa yang sudah dikerjakan>
   Belum selesai: <apa yang masih outstanding>
   File relevan: <list file yang perlu dibaca di sesi berikutnya>
   ```
   Simpan di `docs/handoff.md`. Sesi berikutnya baca file ini + `git log`, bukan mewarisi history.

5. **RTK hanya untuk tool eksternal** (`git`, `npm`, `docker`, `gh`, `cargo`, dll).
   Jangan prefix command PowerShell native dengan `rtk` — cmdlet PS tidak difilter RTK
   dan mengaburkan output verifikasi yang butuh presisi.
   Catatan: RTK mengompresi output command, bukan history — lever sekunder, bukan utama.

### Konvensi file handoff

File: `docs/handoff.md` di root repo. Diperbarui setiap akhir sesi yang produktif.
Sesi berikutnya WAJIB baca file ini sebelum melanjutkan pekerjaan.

### Aturan untuk regression test baru

Setiap test baru yang diklaim "membuktikan fix" harus pernah diobservasi GAGAL terhadap
kode yang belum diperbaiki sebelum dianggap valid. Kenaikan angka hijau bukan bukti —
justru itu yang paling mudah disalahartikan. Verifikasi dengan menjalankan test terhadap
build lama atau versi stripped sebelum commit.

---

## Aturan Umum

- Selalu baca file yang relevan sebelum membuat klaim tentang kode
- Jangan hardcode versi atau build number — baca dari sumber yang selalu update
- Jika ragu changelog ada di mana, cari dulu sebelum bertanya ke user
- Prioritaskan data aktual (screenshot terbaru, git log, file terbaru) di atas asumsi
- Jika ada dua sumber informasi yang konflik, sebutkan konfliknya ke user
