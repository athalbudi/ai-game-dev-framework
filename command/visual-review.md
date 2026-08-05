---
description: >
  Penilaian visual yang awet lintas sesi, dipatok ke gambar yang dinilai.
  Contoh: /visual-review plan | /visual-review record | /visual-review check
---

Kamu mengelola verdict visual — penilaian tentang apakah sebuah layar BENAR, bukan sekadar
apakah ia berubah.

## Kenapa ini ada

`visual-diff` membandingkan pixel: ia tahu sebuah layar berubah, tapi tidak pernah tahu
layar itu benar. Teks terpotong, mojibake, tombol tertutup panel, kontras yang tak terbaca —
semua itu hanya bisa dinilai dengan MELIHAT.

Dan penilaian itu selama ini hilang begitu percakapan selesai. Tool ini menjadikannya
artefak: verdict tersimpan, dipatok ke sha256 gambar yang benar-benar dinilai, dan `check`
akan terus melaporkannya di sesi mana pun sampai diperbaiki.

## Berkas yang terlibat

| Berkas | Isi |
|---|---|
| `<project>/scenarios/visual-claims.json` | klaim apa yang dinilai (kamu yang menyusun) |
| `<shots>/visual-review.json` | verdict tersimpan |
| `<shots>/visual-review/judged/` | salinan gambar yang dinilai — JANGAN dihapus |
| `<shots>/visual-review-worklist.json` | daftar yang perlu dinilai, hasil `plan` |

## /visual-review plan

```bash
visual-review.ps1 -ProjectPath <game> -Mode plan
```

Menghasilkan worklist berisi pasangan (screenshot × klaim) yang **belum dinilai** atau
**basi**. Kerjakan daftar ini, jangan menebak yang lain.

## Menilai gambar — bagian yang hanya bisa kamu lakukan

Untuk tiap item di worklist, BUKA gambarnya dan jawab klaimnya. Aturan yang harus kamu
pegang:

- **Baca maksimal 6 gambar per batch, baca semuanya dulu, baru simpulkan.** Kalau ada
  gambar yang gagal terbaca, laporkan itu — jangan menarik kesimpulan tentangnya.
- **Nilai HANYA gambar yang benar-benar kamu lihat.** Menebak sisanya merusak seluruh nilai
  sistem ini.
- **Terpotong di lipatan area bergulir BUKAN cacat.** Kalau ada scrollbar, pemotongan di
  lipatan adalah sifat wajar container bergulir. Menggagalkannya akan menggagalkan setiap
  layar bergulir selamanya, dan orang akan mematikan pemeriksaan ini dalam sehari.
- Kalau kamu menemukan sesuatu yang nyata tapi di luar daftar klaim (mis. angka yang tidak
  konsisten), **laporkan sebagai catatan, jangan paksakan jadi verdict**. Usulkan klaim atau
  invariant baru untuknya.

## /visual-review record

Tulis berkas verdict lalu catat:

```json
{ "verdicts": [
  { "file": "01_title.png", "claim_id": "karakter_tidak_rusak",
    "verdict": "fail", "note": "Mojibake di 4 dari 7 tombol menu: ..." }
]}
```

```bash
visual-review.ps1 -ProjectPath <game> -Mode record -VerdictFile <file>
```

`verdict`: `pass` | `fail` | `na`. **Verdict `fail` WAJIB menyertakan `note`** dan akan
ditolak tanpanya — vonis tanpa alasan tidak berguna bagi siapa pun yang membacanya nanti,
termasuk kamu di sesi berikutnya. Tulis note yang menyebut APA dan DI MANA, bukan "terlihat
salah".

## /visual-review check

```bash
visual-review.ps1 -ProjectPath <game> -Mode check
```

Exit 1 bila ada verdict `fail`, atau masih ada yang belum dinilai/basi.
`-AllowUnjudged` mempersempitnya ke verdict `fail` saja.

**Fail-closed:** proyek yang belum pernah dinilai HARUS gagal. Diam bukan bukti bahwa
tampilannya benar.

## Bagaimana verdict jadi basi

Verdict dipatok ke sha256 gambar yang dinilai. Saat gambar berubah:

- **di bawah `threshold_pct`** (default 2%) → verdict `pass` dibawa maju, ditandai
  `carried_from` dan `drift_pct`. Ini ada supaya game dengan screen-shake tidak
  membatalkan semua verdict tiap run.
- **di atas ambang** → basi, wajib dinilai ulang.
- **verdict `fail` TIDAK PERNAH dibawa maju.** Sebuah perbaikan bisa menentukan secara
  visual namun kecil dalam hitungan pixel; melaporkan bug yang sudah diperbaiki merusak
  kepercayaan sama parahnya dengan melewatkan bug.

Penyimpangan selalu diukur terhadap gambar yang BENAR-BENAR dinilai, bukan terhadap run
sebelumnya — jadi ia terkurung permanen di bawah ambang dan tidak bisa menumpuk.

## Urutan yang disarankan

1. Salin `scenarios-templates/visual-claims.json` ke `<project>/scenarios/`, sesuaikan
2. `plan` → dapat worklist
3. Lihat gambarnya, batch ≤6
4. `record`
5. `check` di CI
