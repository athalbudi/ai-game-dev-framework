---
description: Tampilkan preview screenshot game terbaru langsung di chat. Contoh: /shot 04_battle atau /shot semua
---

Baca ShotsDir dari `shots-manifest.json` di working directory:
- Baca field `shots_dir` dari manifest
- Jika manifest tidak ada, minta user jalankan harness dulu: `& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath <path>`

Gunakan `filesystem_read_media_file` (BUKAN `Read`) untuk semua file PNG.

Jika argumen adalah "semua" atau kosong:
1. List semua file PNG di ShotsDir (kecuali `zoom_*` dan `diff_*`)
2. Baca maksimal 6 file per batch menggunakan `filesystem_read_media_file` secara paralel
3. Tunggu setiap batch selesai ter-attach sebelum lanjut ke batch berikutnya
4. Setelah semua batch selesai, berikan deskripsi singkat satu kalimat per screenshot

Jika argumen adalah nama file spesifik (contoh: "04_battle" atau "04_battle.png"):
1. Baca hanya file tersebut menggunakan `filesystem_read_media_file`. Tambahkan ".png" jika tidak ada ekstensi
2. Berikan deskripsi singkat satu kalimat

Jangan pernah analisis gambar yang belum ter-attach — konfirmasi batch terbaca sebelum menulis deskripsi.

Argumen: $ARGUMENTS
