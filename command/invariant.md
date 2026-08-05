---
description: >
  Aturan game yang diperiksa setelah SETIAP langkah scenario, bukan di satu titik.
  Contoh: /invariant init | /invariant list | /invariant check | /invariant add <ide>
---

Kamu mengelola invariant — klaim tentang game yang harus benar sepanjang run.

## Kenapa ini ada

`assert_state` bersifat posisional: ia hanya memeriksa di titik tempat penulis scenario
menaruhnya. Bug yang terjadi DI ANTARA dua assertion tidak pernah terlihat.

Invariant diperiksa setelah setiap langkah, di semua scenario. Karena itu ia satu-satunya
pemeriksaan yang bisa menangkap kelas "pemain melompati sesuatu": progres naik tanpa usaha
yang mendahuluinya. Itu bug yang tidak akan pernah muncul dari suite scenario, seberapa pun
banyaknya, karena scenario hanya mengunjungi apa yang sudah dipikirkan penulisnya.

## Di mana invariant tinggal

- `res://scenarios/invariants.json` — berlaku untuk SEMUA scenario game ini, tanpa satu pun
  scenario perlu diubah. Ini sumber nilai terbesarnya.
- Kunci `"invariants"` di dalam satu file scenario — hanya untuk scenario itu.

Keduanya digabung saat scenario berjalan.

## Bentuk satu invariant

```json
{
  "id": "progres_butuh_usaha",
  "expr": "delta.level_selesai <= delta.musuh_dikalahkan",
  "description": "Level tidak boleh bertambah selesai tanpa ada musuh yang dikalahkan.",
  "severity": "critical"
}
```

Tiga variabel tersedia di `expr`, dievaluasi lewat `Expression` bawaan Godot:

| Variabel | Isi |
|---|---|
| `prev` | game_state SEBELUM langkah |
| `curr` | game_state SESUDAH langkah |
| `delta` | selisih numerik `curr - prev` |

`delta` HANYA memuat field numerik yang ada di `prev` DAN `curr`. Field yang baru muncul
tidak diberi delta — kalau dipaksakan jadi 0, invariant seperti `delta.seals <= delta.wins`
akan lolos diam-diam justru saat datanya belum ada.

Akses bersarang bekerja: `curr.dukun.hp <= curr.dukun.max_hp`.

## Perilaku saat dilanggar

- Pelanggaran **dicatat, run LANJUT**. Satu run harus bisa memanen semua pelanggaran
  sekaligus; fail-fast di sini juga akan membuat step `explore` tidak berguna karena
  pelanggaran pertama mengakhiri penjelajahan.
- Di-**dedup per `id`**: kejadian pertama disimpan lengkap (prev/curr/delta/langkah),
  berikutnya hanya menambah `count`. Satu kondisi yang terus rusak tidak membanjiri laporan.
- `severity: "critical"` → status akhir scenario jadi `fail` dan **exit 1**.
  `severity: "warning"` → hanya dicatat.
- `"fail_fast": true` per-invariant untuk kasus yang memang tak bermakna dilanjutkan
  (mis. save sudah rusak).

## Perintah yang didukung

### /invariant init
1. Salin `scenarios-templates/invariants.json` dari `~/.config/kilo/` ke
   `<project>/scenarios/invariants.json`.
2. Baca `game_state.json` di ShotsDir untuk melihat field apa yang BENAR-BENAR tersedia.
3. Sesuaikan setiap `expr` ke nama field game ini. Hapus contoh yang tidak berlaku —
   invariant yang menyebut field tak ada akan gagal dievaluasi dan dilewati diam-diam.

### /invariant list
Tampilkan isi `scenarios/invariants.json` beserta invariant inline di tiap scenario.

### /invariant check
Jalankan satu scenario, lalu baca `scenario_result.json`:

| Field | Arti |
|---|---|
| `invariants_total` | berapa invariant aktif |
| `invariant_checks` | berapa kali dievaluasi (invariant × langkah) |
| `invariant_violations` | daftar pelanggaran, sudah ter-dedup |

**`invariant_checks` bernilai 0 berarti tidak ada yang diuji** — biasanya file invariants
tidak ditemukan, atau game tidak menyediakan `_get_game_state()`.

### /invariant add \<ide\>
Bantu user merumuskan satu invariant baru dari deskripsi bahasa manusia:
1. Baca `game_state.json` untuk tahu field yang tersedia.
2. Rumuskan `expr` yang HANYA memakai field itu.
3. Jalankan satu scenario untuk memastikan ia dievaluasi (bukan dilewati).
4. Kalau bisa, buktikan ia BISA dilanggar — invariant yang tidak mungkin gagal tidak
   menguji apa pun.

## Yang harus kamu ingatkan ke user

Invariant **tidak bisa disimpulkan framework**. Ia menyatakan maksud desain, dan itu hanya
ada di kepala pembuat game. Biayanya kecil — 5–10 baris JSON per game sudah menutup
sebagian besar — dan ia berlaku ke seluruh scenario yang sudah ada tanpa satu pun diubah.
