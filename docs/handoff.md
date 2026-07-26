## Handoff — 2026-07-26

Commit terakhir: 8711c72 docs: tambah protokol efisiensi token dan aturan regression test ke AGENTS.md

Status: working tree ada perubahan (AGENTS.md sudah diedit, belum di-commit)

### Selesai di sesi ini
- 16/16 test PASS
- EAP save/restore di Test-ProtectedFileViolation dan Test-ScopeViolation
- TEST 11 ditulis ulang dengan behavioral correctness (unstaged files + CRLF baseline)
- -PatchRef auto-wiring dari -PatchBranch saat FixLoopMode aktif
- TEST 10 +1 assertion untuk verifikasi two-ref diff
- AGENTS.md diperbarui dengan protokol efisiensi token (versi pertama)
- AGENTS.md diperbarui lagi dengan: kuota hitung token mentah, konvensi handoff, RTK dipersempit ke tool eksternal saja, tabel estimasi penghematan
- Fix-loop otonom pertama dijalankan di godot-open-rts (bug scene value, scenario PASS)

### Belum selesai / outstanding
- AGENTS.md update terbaru belum di-commit (edit sudah diterapkan)
- Prompt caching: Kilo Code menyisipkan Current time di setiap request = silent invalidator, caching tidak aktif
- godot-open-rts: instrumentasi minimal, smoke PASS, tapi coverage masih minimal (2 screenshot)
- JIMAT: QA terakhir 36 PNG, 100%, tapi sudah beberapa sesi tidak dijalankan

### File relevan untuk sesi berikutnya
- `docs/handoff.md` (file ini)
- `tools/run-and-analyze.ps1` — gate functions, -FixLoopMode, -PatchRef auto-wiring
- `tools/test-pipeline.ps1` — TEST 11 behavioral correctness, TEST 10 two-ref assertion
- `AGENTS.md` — protokol efisiensi token (lihat bagian "Aturan Efisiensi Token")

### Catatan efisiensi token
- Sesi ini sangat panjang (~100+ exchange) karena relay audit manual
- Gunakan sesi baru per task mulai sekarang
- Rotasi di ~20 exchange, tulis handoff sebelum tutup
- Baca range bukan file penuh (3 file utama = 40K token kalau dibaca utuh)
