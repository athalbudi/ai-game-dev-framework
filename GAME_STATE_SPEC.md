# GAME_STATE_SPEC.md
# Kontrak game_state.json — AI Game Development Framework

Berlaku untuk semua project yang menggunakan framework ini.
Versi spec: 1.0 | Terakhir diupdate: 2026-07-20

---

## Ringkasan

`game_state.json` adalah file JSON yang ditulis oleh game saat `--shot` mode atau
`--scenario` mode berjalan. File ini dibaca oleh harness dan autonomous-qa untuk
memperkaya analisis visual dengan konteks internal game.

File ditulis ke: `user://shots/game_state.json`
(Godot: `%APPDATA%\Godot\app_userdata\<nama_project>\shots\game_state.json`)

---

## Prinsip Desain

1. **Progressive capability** — harness tidak crash jika file tidak ada.
   Fase telemetry dideteksi otomatis berdasarkan keberadaan file.
2. **Schema bebas di luar core** — field universal wajib ada, sisanya bebas.
3. **Backward compatible** — harness membaca field yang dikenali, ignore sisanya.
4. **Tidak ada schema enforcement** — game tidak perlu validasi sisi harness.

---

## Fase Telemetry (Auto-detect)

| Fase | Kondisi | Kemampuan AI |
|---|---|---|
| `prototype` | Tidak ada PNG, tidak ada `game_state.json` | Tahu game belum bisa di-screenshot |
| `developing` | Ada PNG, tidak ada `game_state.json` | Analisis visual murni |
| `mature` | Ada PNG **dan** ada `game_state.json` | Visual + konteks internal game |

---

## Layer 0: Universal Core (WAJIB, semua game)

Field ini wajib ada di setiap implementasi `game_state.json`.
Jika tidak ada, harness anggap fase `developing`.

```json
{
  "schema_version": "1.0",
  "build": "0.20a",
  "timestamp": "2026-07-20T17:30:00",
  "current_scene": "MainMenu",
  "frame_count": 3600,
  "error_log": []
}
```

### Field Definitions

| Field | Type | Keterangan |
|---|---|---|
| `schema_version` | string | Versi spec ini. Saat ini `"1.0"`. |
| `build` | string | Versi build game. Baca dari konstanta game, jangan hardcode. |
| `timestamp` | string | ISO 8601. `Time.get_datetime_string_from_system()` di Godot. |
| `current_scene` | string | Nama scene/layar yang aktif saat `write_state` dipanggil. |
| `frame_count` | int | `Engine.get_process_frames()` di Godot. Berguna untuk deteksi hang. |
| `error_log` | array | Array string error yang terjadi selama sesi. Kosong = tidak ada error. |

---

## Layer 1: Session Context (Direkomendasikan)

Field yang membantu AI memahami konteks sesi tanpa game-specific knowledge.

```json
{
  "run_active": false,
  "session_duration_sec": 42.5,
  "session_events": [
    { "t": 1.2, "event": "scene_changed", "data": "MainMenu" },
    { "t": 5.8, "event": "user_action",   "data": "ui_accept" }
  ]
}
```

| Field | Type | Keterangan |
|---|---|---|
| `run_active` | bool | Apakah game sedang dalam sesi aktif (run, level, match). |
| `session_duration_sec` | float | Lama sesi berjalan dalam detik. |
| `session_events` | array | Array event penting selama sesi untuk replay/debugging. |

### Format `session_events` entry

```json
{ "t": 1.23, "event": "nama_event", "data": "nilai_opsional" }
```

`t` = detik sejak game start. `event` = string bebas. `data` = opsional, string atau object.

---

## Layer 2: Player State (Opsional, fase developing+)

Tersedia setelah game memiliki player system. Semua field opsional.

```json
{
  "player": {
    "hp": 80,
    "max_hp": 100,
    "hp_pct": 0.8,
    "level": 3,
    "position": { "x": 120.5, "y": 340.0 },
    "state": "idle"
  }
}
```

Tidak ada schema ketat — sesuaikan dengan sistem game. AI akan membaca field yang ada.

---

## Layer 3: World / Environment State (Opsional, fase mature)

```json
{
  "world": {
    "current_level": "dungeon_floor_2",
    "enemies_alive": 3,
    "enemies_total": 5,
    "time_of_day": "night",
    "flags": ["boss_defeated", "chest_opened"]
  }
}
```

---

## Layer 4: Full Telemetry (Opsional, fase production)

Untuk game yang sudah mature dan ingin full autonomous QA:

```json
{
  "economy": {
    "currency": 150,
    "resources": { "wood": 20, "stone": 5 }
  },
  "inventory": {
    "items": ["sword", "potion_x2"],
    "capacity": 10,
    "used": 3
  },
  "progression": {
    "quests_active": 2,
    "quests_completed": 5,
    "achievements": ["first_kill", "speedrunner"]
  },
  "combat": {
    "in_combat": false,
    "last_damage_dealt": 45,
    "last_damage_taken": 12
  },
  "ai_agents": [
    { "id": "enemy_01", "state": "patrol", "hp": 60 }
  ]
}
```

---

## Implementasi di Godot 4

### Minimal (fase prototype → developing)

```gdscript
# Taruh di node main atau autoload
func _write_game_state() -> void:
    var state := {
        "schema_version": "1.0",
        "build":          "0.1a",           # ganti dengan konstanta build kamu
        "timestamp":      Time.get_datetime_string_from_system(),
        "current_scene":  _get_current_scene_name(),
        "frame_count":    Engine.get_process_frames(),
        "error_log":      [],
    }
    DirAccess.make_dir_recursive_absolute("user://shots")
    var f := FileAccess.open("user://shots/game_state.json", FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(state, "\t"))
        f.close()

func _get_current_scene_name() -> String:
    # Sesuaikan dengan cara game kamu mengelola scene
    return get_tree().current_scene.name if get_tree().current_scene else "unknown"
```

### Dengan GameStateWriter autoload (direkomendasikan)

Install `GameStateWriter.gd` (dari `godot-templates/`) sebagai autoload, lalu:

```gdscript
func _write_game_state() -> void:
    GameStateWriter.write({
        "schema_version": "1.0",
        "build":          MY_VERSION_CONSTANT,
        "timestamp":      Time.get_datetime_string_from_system(),
        "current_scene":  _get_current_scene_name(),
        "frame_count":    Engine.get_process_frames(),
        "error_log":      ErrorTracker.get_errors() if has_node("/root/ErrorTracker") else [],
        # tambah field game-specific di sini
    })
```

### Hook ke ScenarioRunner

`ScenarioRunner` mencari method `_write_game_state()` di scene tree secara otomatis
via `_find_nodes_with_method(get_tree().root, "_write_game_state")`.

Tidak perlu registrasi manual — cukup method ini ada di node manapun di tree.

---

## Debugging: Mengapa game_state.json Tidak Terbaca

1. **Path salah** — pastikan menulis ke `user://shots/game_state.json`, bukan `res://`.
2. **DirAccess tidak dipanggil** — `user://shots/` harus dibuat dulu sebelum FileAccess.
3. **JSON tidak valid** — gunakan `JSON.stringify(state, "\t")`, bukan manual concat.
4. **Ditulis setelah quit** — pastikan `_write_game_state()` dipanggil sebelum `get_tree().quit()`.
5. **--shot mode tidak trigger write** — pastikan `_write_game_state()` dipanggil di `_shot_tour()`.

---

## Hubungan Tiga Layer Observasi

```
screenshot (visual)  +  shots-manifest.json (metadata)  +  game_state.json (internal)
        │                          │                                │
        ▼                          ▼                                ▼
  "Layar ini         "Diambil 2 menit setelah      "run_active=true, HP 40%,
   terlihat rusak"    launch, ada 18 shot total"    3 enemy di field"
        │                          │                                │
        └──────────────────────────┴────────────────────────────────┘
                                   │
                                   ▼
                    AI memahami game secara menyeluruh:
                    visual + timing + internal state
```

Kombinasi ketiganya memungkinkan analisis yang tidak mungkin dilakukan
hanya dari screenshot atau hanya dari kode.

---

## screen-index.json — Input untuk feedback-bridge.ps1

`screen-index.json` adalah file yang wajib ada di project root agar `feedback-bridge.ps1` bisa
menghubungkan teks feedback playtester ke screenshot, komponen UI, dan lokasi kode.

Gunakan `screen-index-template.json` di root repo ini sebagai titik awal, lalu sesuaikan dengan
struktur layar dan komponen game Anda.

### Schema

```json
{
  "project": "string — nama game",
  "build":   "string — versi build (contoh: 0.1.0)",
  "shots_dir": "string — path absolut ke folder screenshot",

  "screens": [
    {
      "screen_id":    "string — ID unik layar (contoh: main_menu)",
      "description":  "string — deskripsi singkat layar",
      "shot_files":   ["array string — nama PNG screenshot (contoh: 01_main_menu.png)"],
      "render_files": ["array string — path file kode yang merender layar ini"],
      "keywords":     ["array string — kata kunci yang muncul di feedback terkait layar ini"],
      "components": [
        {
          "name":       "string — nama komponen UI",
          "file":       "string — path file kode komponen",
          "key_issues": ["array string — isu umum pada komponen ini"],
          "keywords":   ["array string — kata kunci feedback terkait komponen ini"]
        }
      ]
    }
  ],

  "global_issues": [
    {
      "issue_id":   "string — ID isu global (contoh: performance_fps)",
      "keywords":   ["array string — kata kunci yang menandai isu ini"],
      "screens":    ["array string — screen_id yang terkait"],
      "components": ["array string — nama komponen yang terkait"]
    }
  ],

  "resolutions": [
    {
      "issue_id": "string — issue_id yang sudah atau sedang ditangani",
      "status":   "string — resolved | in_progress | persistent",
      "note":     "string — catatan singkat tentang penanganan"
    }
  ]
}
```

### Catatan penggunaan

- `keywords` di level `screen` dan `component` dicocokkan terhadap teks feedback (case-insensitive).
- `global_issues` dicocokkan ke seluruh teks feedback, tidak terikat ke satu layar.
- `resolutions` menandai isu yang sudah ditangani — bridge menampilkan status ini di output.
- Jika `shot_files` tidak ditemukan di `shots_dir`, bridge tetap berjalan tapi menandai screenshot sebagai hilang.
- Lihat `screen-index-template.json` di root repo untuk contoh lengkap yang siap dimodifikasi.

---

## fix-request.json — Kontrak untuk AI-driven fix loop

`fix-request.json` adalah output `AnomalyDetector.build_fix_requests()` — menjembatani anomali yang
terdeteksi (dari `shots-manifest.json`, `game_state.json`, `scenario_result.json`) ke bentuk yang bisa
langsung dieksekusi oleh agent penulis kode, tanpa agent itu sendiri yang menentukan apakah anomalinya
layak ditindaklanjuti.

### Prinsip desain

1. **`reproducing_scenario` harus menunjuk ke scenario yang sudah ada**, bukan yang di-generate agent
   dalam iterasi yang sama dengan fix-nya. Agent yang menulis scenario verifikasi untuk fix-nya sendiri
   adalah pola yang sama dengan kegagalan yang berulang di `test-pipeline.ps1` TEST 7 — validator dan
   yang divalidasi berbagi asumsi (dan blind spot) yang sama.
2. **Fix-request tanpa scenario yang cocok tetap dihasilkan, tapi berstatus `blocked_no_scenario`** —
   bukan dibuang diam-diam. Ini agar manusia tahu ada anomali yang butuh scenario baru ditulis (oleh
   manusia atau lewat proses review terpisah) sebelum anomali itu bisa masuk fix loop otomatis.
3. Field mengikuti struktur anomaly yang sudah ada di `autonomous-qa.ps1` (`Detect-Anomalies`) dan
   `AnomalyDetector.gd` (`detect_all()`) — `fix-request.json` tidak menambah taksonomi baru, hanya
   memperkaya anomaly yang sudah terdeteksi dengan pointer eksekusi (`reproducing_scenario`, `status`).

### Schema

```json
{
  "schema_version": "string — versi kontrak ini, saat ini \"1.0\"",
  "generated_at":   "string — ISO 8601 timestamp saat fix-request dibuat",

  "fix_requests": [
    {
      "fix_request_id": "string — id unik, biasanya <anomaly.id>_<timestamp>",
      "source":         "string — anomaly | feedback",
      "type":           "string — visual | state | scenario | performance | coverage | scenario_drift",
      "severity":       "string — critical | warning | info",
      "description":    "string — deskripsi teknis anomali",
      "evidence":       "object — data konkret pendukung (nilai aktual vs ekspektasi)",
      "target_file":    "string — screenshot atau file kode yang terkait, boleh kosong",
      "suggested_action": "string — langkah investigasi yang disarankan",
      "step_hint":      "string — step type ScenarioRunner yang relevan",
      "reproducing_scenario": "string atau null — path scenario JSON yang SUDAH ADA di scenarios/ dan mereproduksi anomali ini secara deterministik. null jika belum ada scenario yang cocok.",
      "status":         "string — actionable (reproducing_scenario terisi) | blocked_no_scenario (masih null)"
    }
  ]
}
```

### Catatan penggunaan

- Hanya fix-request dengan `status: "actionable"` yang boleh masuk ke tahap eksekusi otomatis (agent
  menulis patch). `blocked_no_scenario` adalah sinyal untuk manusia, bukan untuk agent — jangan biarkan
  agent membuat scenario baru sendiri hanya untuk mengubah status ini menjadi `actionable`.
- Korelasi `target_file` → `reproducing_scenario` dilakukan dengan mencocokkan step di setiap file
  `scenarios/*.json` terhadap `target_file` (mis. step `screenshot`/`assert_screenshot_exists` dengan
  `name` yang cocok, atau `assert_state` dengan `key` yang menyentuh field terkait). Kalau tidak ada
  yang cocok, `reproducing_scenario` tetap `null` — tidak ada fallback ke pencarian samar.
- Lihat `fix-request-template.json` di root repo untuk contoh lengkap.
- Gate verifikasi (lihat `run-and-analyze.ps1` — `Test-ProtectedFileViolation`) memperlakukan file yang
  dirujuk `reproducing_scenario` sebagai protected — patch yang mengubah file itu sendiri gagal
  verifikasi tanpa terkecuali, terlepas dari hasil scenario/visual-diff lainnya.
