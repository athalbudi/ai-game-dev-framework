---
description: >
  Eksplorasi otomatis: menekan tombol nyata di layar dengan invariant hidup, lalu memperkecil
  jejaknya jadi repro minimal. Contoh: /explore | /explore 60 | /explore minimize
---

Kamu menjalankan eksplorasi — menekan tombol yang benar-benar ada di layar secara acak,
dengan invariant diperiksa setelah SETIAP klik.

## Kenapa ini ada

Scenario tertulis hanya mengunjungi apa yang sudah dipikirkan penulisnya. Bug "konten bisa
dilewati" justru hidup di jalur yang TIDAK terpikirkan — jadi ia tidak akan pernah muncul
dari suite scenario, sebanyak apa pun.

Eksplorasi tanpa invariant cuma menghasilkan screenshot. Invariant tanpa eksplorasi cuma
menjaga jalur yang sudah aman. Nilainya muncul dari gabungan keduanya. **Pastikan
`scenarios/invariants.json` ada sebelum menjalankan ini** — kalau tidak, step ini akan
memperingatkan bahwa ia tidak memeriksa apa pun.

## Bentuk step

```json
{
  "type": "explore",
  "iterations": 40,
  "seed": 20260804,
  "settle_frames": 12,
  "warmup_frames": 90,
  "avoid_text": ["Quit", "Keluar", "Exit"]
}
```

| Field | Arti |
|---|---|
| `iterations` | berapa klik dicoba |
| `seed` | wajib diisi kalau jejaknya ingin bisa diputar ulang |
| `settle_frames` | jeda setelah tiap klik sebelum invariant diperiksa |
| `warmup_frames` | jeda sebelum klik pertama, ditulis juga ke file replay |
| `avoid_text` | label tombol yang tidak boleh diklik — selalu sertakan tombol keluar |
| `stop_on_violation` | berhenti pada pelanggaran pertama (default false) |
| `require_clicks` | set false HANYA untuk game yang tidak digerakkan tombol |

## Cara ia memilih target

Menelusuri scene tree mencari `BaseButton` yang benar-benar bisa ditekan pemain: terlihat
di tree, tidak `disabled`, punya luas, dan berpotongan dengan viewport. Lalu mengklik titik
tengahnya.

Sengaja mengklik Control, BUKAN mengirim `action ui_*`. Tanpa Control yang fokus, `ui_*`
tidak mengenai apa pun — dan itu kondisi yang lebih umum daripada dugaan orang.

## Membaca hasilnya

Di `scenario_result.json`, cari step bertipe `explore`:

| Field | Yang harus kamu perhatikan |
|---|---|
| `clicked` | **0 = step GAGAL.** Tidak ada perilaku game yang teruji sama sekali |
| `dead_ends` | iterasi tanpa satu tombol pun bisa diklik |
| `unique_buttons` | luas jangkauan eksplorasi |
| `buttons` | label tombol yang ditekan — periksa apakah ia benar-benar masuk gameplay |
| `violations` | jumlah invariant yang jebol |
| `replay` | path jejak, terisi kalau ada pelanggaran |

**`clicked: 0` selalu FAIL, tidak pernah pass.** Eksplorasi yang tidak mengklik apa pun
tidak mengeksplorasi apa pun, dan melaporkannya lulus adalah false-verify paling murni.
Dua penyebab tersering: game mengambil jalur init minimal saat `--scenario` dan menampilkan
layar kosong, atau UI-nya tidak dibangun dari `BaseButton`.

Kalau `buttons` hanya berisi tombol menu dan `game_state` tidak pernah berubah, eksplorasi
tidak pernah menembus ke gameplay — laporkan itu, jangan diamkan.

## /explore minimize

Setelah invariant jebol, jejak lengkap ditulis ke `user://shots/explore_replay.json`.
Jejak 40 klik benar tapi nyaris tak terpakai; yang dibutuhkan adalah KLIK MANA penyebabnya.

```bash
explore-minimize.ps1 -ProjectPath <game> -InvariantId <id>
```

Prosesnya menjalankan ulang subset jejak di proses Godot BARU sampai menemukan urutan
terpendek yang masih melanggar invariant yang sama. Keluarannya `explore_repro.json` —
scenario siap jalan, layak dijadikan test regresi.

Yang perlu kamu tahu saat membaca keluarannya:

- **Baseline diverifikasi lebih dulu dan gagal tertutup.** Kalau jejak penuh saja tidak
  mereproduksi, tool berhenti dan menyebut sebabnya. Memperkecil jejak yang tidak
  reproducible menghasilkan file yang tampak berguna tapi tidak pernah bekerja.
- Penyebab tersering jejak tidak reproducible: seed tidak diisi, atau game menyimpan
  kemajuan di `user://` sehingga run kedua berangkat dari keadaan berbeda.
- Replay memakai **label tombol**, bukan koordinat. Replay tetap sah setelah layout bergeser,
  dan kalau tombolnya tidak ada, langkahnya gagal dengan daftar tombol yang sebenarnya
  tersedia — bukan mengklik tempat kosong lalu lolos diam-diam.
- Pembuangan mencoba **jendela berurutan sampai 4 klik**, bukan satu-satu. Navigasi datang
  berpasangan ("masuk menu", lalu "Back"); membuang salah satunya membuat pasangannya tidak
  punya tombol untuk ditekan. Terukur pada jimat: satu-satu mentok di 5 dari 5 klik,
  berjendela menyusut ke 1.
- Batasnya tetap ada: **jendela lebih panjang dari 4 tidak dicoba**, dan pembuangan hanya
  berurutan — dua klik tak bersebelahan yang cuma bisa pergi bersama tidak akan ditemukan.
  Jejak panjang mungkin perlu `-MaxRuns` lebih besar dari 40.

## Urutan yang disarankan

1. `/invariant init` — tanpa invariant, eksplorasi tidak memeriksa apa pun
2. `/explore` — periksa `clicked` dan `buttons` lebih dulu, sebelum melihat pelanggaran
3. `explore-minimize.ps1` — kalau ada pelanggaran
4. Simpan `explore_repro.json` sebagai scenario regresi
