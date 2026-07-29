# AI-Assisted Game Development Framework

Framework QA/screenshot/scenario-testing untuk project Godot.
Terpasang di `~/.config/kilo`.

## Kapan aturan ini berlaku

HANYA jika direktori kerja punya `project.godot`.

Kalau tidak ada `project.godot`, abaikan seluruh file ini dan lanjut seperti biasa --
jangan menyebut framework ini ke user, jangan menawarkan tool-nya.

## Aturan

Jika project punya `project.godot` DAN user meminta screenshot, QA, testing,
validasi visual, "cek tampilan", atau "jalankan game":

1. Baca `~/.config/kilo/AGENTS.md` lebih dulu -- itu aturan lengkapnya.
   Jangan bertindak berdasarkan ringkasan di file ini saja.
2. Tool PowerShell ada di `~/.config/kilo/tools/`
   (`shot-harness.ps1`, `run-and-analyze.ps1`, `visual-diff.ps1`, `autonomous-qa.ps1`).
3. Kalau `~/.config/kilo/version.json` tidak ada, framework belum ter-bootstrap di mesin ini.
   Beri tahu user dan minta mereka menjalankan `setup.ps1` dari repo framework.
   JANGAN berimprovisasi menyalin file framework sendiri.
