---
description: >
  Pemeriksaan statis terhadap PROJECT GAME — cacat yang tidak akan pernah terlihat dari
  screenshot. Contoh: /game-doctor | /game-doctor strict
---

Kamu menjalankan pemeriksaan statis terhadap project game.

`doctor.ps1` memeriksa kesehatan INSTALASI framework. Tool ini memeriksa game-nya.

## Kenapa ini ada

Framework hanya melihat apa yang berhasil dirender. Sebagian cacat tidak pernah sampai ke
screenshot — ia mematikan sesuatu lebih dulu, atau ia berupa teks yang salah sejak di
sumbernya. Cacat semacam itu tadinya hanya ketemu kalau ada orang yang kebetulan curiga dan
mengetik `grep`.

## Menjalankan

```bash
game-doctor.ps1 -ProjectPath <game>
```

Deterministik, tanpa menjalankan Godot, selesai dalam hitungan detik.
`-Strict` membuat `warning` ikut menggagalkan. `-IncludeAddons` ikut memeriksa plugin
pihak ketiga (default dilewati). Laporan ditulis ke `game-doctor-report.json`.

Exit 1 bila ada `error`.

## Yang diperiksa

| Id | Severity | Arti |
|---|---|---|
| `class_name_ganda` | error | dua script mendaftarkan `class_name` sama — Godot menolak memuat KEDUANYA |
| `mojibake` | error/warning | teks ter-encode ganda; error bila sampai ke string UI |
| `shot_tour_dipanggil_game` | error | game memanggil `_shot_tour` sendiri, jadi dua tur berjalan bersamaan |
| `autoload_hilang` | error/warning | `ErrorTracker` / `GameStateWriter` tidak terdaftar |
| `tanpa_grab_focus` | warning | project bertombol tapi tidak pernah `grab_focus()` |
| `scenario_berhenti_dini` | warning | cabang `--scenario` tampak `return` sebelum layar dibangun |
| `tanpa_penyedia_state` | warning | tidak ada `_get_game_state()` / `_write_game_state()` |
| `template_menyimpang` | warning | salinan template di game beda dari versi framework |
| `step_type_tak_dikenal` | error | scenario memakai step type yang tidak diimplementasikan, termasuk yang bersarang di `repeat` |
| `scenario_kosong` | warning | `"steps": []` — scenario itu sekarang berakhir `inert`, bukan `pass` |
| `tanpa_invariant` / `tanpa_klaim_visual` | info | `scenarios/` ada tapi belum dipakai |

Daftar step type yang sah **dibaca dari `KNOWN_STEP_TYPES` di `ScenarioRunner.gd`**, bukan
disalin ke sini. Salinan kedua yang tertinggal satu versi akan menuduh step type yang
sebenarnya sah, dan pemeriksa yang menuduh salah akan dimatikan orang. Kalau daftar itu tidak
bisa dibaca, pemeriksaannya menyebut dirinya tidak berjalan (`step_type_tak_terperiksa`)
alih-alih membanjiri laporan dengan tuduhan palsu.

Runner memang menggagalkan step type asing saat dijalankan, tetapi baru setelah Godot
diluncurkan — pada scenario panjang, setelah menunggu semua langkah sebelumnya. Salah ketik
adalah kesalahan statis dan layak ketahuan statis.

## Tiga temuan yang paling sering disalahpahami

**`class_name_ganda`** — yang gagal BUKAN hanya salinannya; yang asli ikut mati dengan
"Class X hides a global script class". Layar yang memakainya lalu tidak pernah terbangun dan
tur screenshot berhenti di tengah tanpa pesan yang menyebut sebabnya. Penyebab tersering:
folder cadangan ditaruh DI DALAM project. Perbaikannya: pindahkan ke luar project, atau
taruh berkas `.gdignore` di direktorinya.

**`mojibake`** — dideteksi lewat uji keterbalikan encoding, bukan daftar karakter. Kalau
perlu diperbaiki: baca sebagai UTF-8, encode ke CP1252, decode lagi sebagai UTF-8. **Lalu
verifikasi dengan menerapkan ulang kerusakan pada hasilnya** — harus menghasilkan isi lama
persis. Tanpa uji itu, substitusi per-karakter berisiko merusak urutan yang kebetulan mirip.

**`scenario_berhenti_dini`** — statis hanya bisa mencurigai, tidak memastikan. Pastikan
dengan menjalankan step `explore`: kalau `clicked` = 0, game memang tidak membangun layarnya
saat `--scenario`.

## Catatan aturan pemindaian

Sebagian besar pemeriksaan melewati direktori arsip (`.`-prefix, `_backup*`, `build`,
`export`, `addons`) untuk menekan kebisingan — pemeriksa yang menuduh arsip cepat kehilangan
kepercayaan.

**`class_name_ganda` sengaja TIDAK memakai daftar itu.** Godot tidak mengenal daftar
tersebut; ia memindai semuanya kecuali direktori berawalan titik dan direktori ber-
`.gdignore`. Justru di folder yang doctor lewati duplikat biasanya bersembunyi. Jangan
"rapikan" kedua daftar itu jadi satu — pemeriksaannya akan melewatkan persis kasus yang
menyebabkannya dibuat.

## Kapan menjalankannya

Sebelum sesi QA apa pun. Cacat di daftar ini mematikan pengujian lain lebih dulu —
menjalankan harness pada project yang `class_name`-nya ganda hanya menghasilkan tur yang
terpotong dan waktu terbuang.
