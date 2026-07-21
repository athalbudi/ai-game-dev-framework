# Game State Templates — _write_game_state()

Template GDScript untuk mengimplementasikan Layer 1 telemetry di berbagai kategori game.

## Arsitektur yang Benar

Layer 1 telemetry terdiri dari DUA komponen terpisah:

1. **`GameStateWriter.gd`** — utility standalone yang daftarkan sebagai Autoload
2. **Template genre** — satu file yang di-attach ke node game untuk mendefinisikan data apa yang ditulis

### Setup di Project Baru

**Langkah 1: Salin `GameStateWriter.gd` ke project**
```
scripts/GameStateWriter.gd  ← dari godot-templates/GameStateWriter.gd
```

**Langkah 2: Daftarkan sebagai Autoload di project.godot**
```ini
[autoload]
GameStateWriter="*res://scripts/GameStateWriter.gd"
```

**Langkah 3: Salin template genre yang sesuai**
```
scripts/GameTelemetry.gd  ← pilih template di bawah, rename bebas
```

**Langkah 4: Panggil dari --shot mode di kode game**
```gdscript
func _ready() -> void:
    if "--shot" in OS.get_cmdline_user_args():
        await get_tree().process_frame  # tunggu inisialisasi selesai
        GameStateWriter.write(_get_game_state())
        _shot_tour()
```

## Template yang Tersedia

| File | Kategori | Cocok untuk |
|---|---|---|
| `universal_minimal.gd` | Semua genre | Game baru / prototype — mulai dari sini |
| `rpg_action.gd` | RPG / Action | Game dengan player, combat, inventory, quest |
| `strategy_resource.gd` | Strategy / Idle | Game dengan resource, unit, economy, turn |
| `platformer_runner.gd` | Platformer / Runner | Game dengan level, collectible, lives, checkpoint |
| `puzzle.gd` | Puzzle | Game dengan level, moves, hint, state board |

## Cara Menulis Game State

Setiap template punya fungsi `_write_game_state()` dan `_get_game_state()`.
Cara pemanggilan dari kode game:

```gdscript
# Opsi 1: Panggil langsung via node yang mengimplementasikan template
GameStateWriter.write(_get_game_state())

# Opsi 2: GameStateWriter mencari node dengan _get_game_state() secara otomatis
GameStateWriter.write_from_node(get_tree().root)
```

## Fase Telemetry

- **Prototype**: belum implement `_write_game_state()` — framework tetap jalan, fase = `prototype`/`developing`
- **Mature**: implement hook → manifest berisi `game_state`, fase = `mature`, AI analisis jauh lebih dalam

## Output

Hook ini menulis file `game_state.json` ke `user://shots/game_state.json`.
Harness membacanya dan meng-embed ke `shots-manifest.json` sebagai field `game_state`.

## Timing yang Benar

Panggil `_write_game_state()` SETELAH:
- `await get_tree().process_frame` (minimal 1 frame setelah scene load)
- Scene dan semua sistem sudah selesai inisialisasi

Panggil SEBELUM:
- `get_tree().quit()` di akhir shot tour
- Setiap screenshot penting yang membutuhkan state terkini

Lihat panduan lengkap di `FRAMEWORK.md` → "Panduan Timing `_write_game_state()`"

---

## Skenario Integrasi Umum

### Skenario 1 — Game dengan Autoload Singleton

Game yang menyimpan state di Autoload (pola paling umum di Godot):

```gdscript
# Di main.gd atau scene utama
func _ready() -> void:
    if "--shot" in OS.get_cmdline_user_args():
        await get_tree().process_frame
        GameStateWriter.write(_get_game_state())
        _shot_tour()

func _get_game_state() -> Dictionary:
    return {
        "schema_version": 1,
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",
        "timestamp": Time.get_datetime_string_from_system(),
        # Baca dari Autoload yang sudah ada di game
        "player": {
            "hp": GameManager.player_hp,       # SESUAIKAN: nama Autoload kamu
            "level": GameManager.player_level,
        },
        "session": {
            "score": GameManager.score,
            "elapsed_sec": int(Time.get_ticks_msec() / 1000.0),
        }
    }
```

### Skenario 2 — State Tersebar di Banyak Node

Ketika state tersebar di banyak node/sistem:

```gdscript
func _get_game_state() -> Dictionary:
    var state := {
        "schema_version": 1,
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",
        "timestamp": Time.get_datetime_string_from_system(),
    }
    # Kumpulkan dari berbagai node — gunakan null-check agar aman
    var player_node := get_tree().get_first_node_in_group("player")
    if player_node:
        state["player"] = {
            "hp": player_node.get("hp"),
            "position": {
                "x": snappedf(player_node.global_position.x, 0.1),
                "y": snappedf(player_node.global_position.y, 0.1),
            }
        }
    var ui_node := get_node_or_null("/root/HUD")
    if ui_node and ui_node.has_method("get_ui_state"):
        state["ui"] = ui_node.call("get_ui_state")
    return state
```

### Skenario 3 — Multiple Scene (Shot Tour Lintas Scene)

Ketika shot tour berpindah antar scene, tulis state di setiap scene:

```gdscript
func _shot_tour() -> void:
    # Scene 1: Main Menu
    await get_tree().process_frame
    GameStateWriter.write(_get_game_state())
    _take_screenshot("01_main_menu")

    # Pindah ke gameplay
    get_tree().change_scene_to_file("res://scenes/game.tscn")
    await get_tree().process_frame
    await get_tree().process_frame  # tunggu scene baru selesai load

    # Scene 2: Gameplay — tulis state baru setelah scene berubah
    GameStateWriter.write(_get_game_state())
    _take_screenshot("02_gameplay")

    get_tree().quit()
```

### Skenario 4 — Game Belum Punya State System (Prototype)

Pada fase prototype, tidak perlu implementasi apapun. Harness tetap berjalan
dan menghasilkan `shots-manifest.json` dengan `telemetry_phase: "developing"`.
AI tetap bisa melakukan visual QA walau tanpa `game_state.json`.

Tambahkan telemetry secara bertahap ketika game mulai punya data yang bermakna.

---

## Apa yang Harus Dimasukkan ke game_state.json

Prioritaskan data yang membantu AI mendiagnosis bug visual:

| Data | Berguna untuk | Contoh |
|---|---|---|
| `scene` | Konfirmasi layar yang benar | `"04_battle"` |
| `player.hp`, `player.hp_max` | Deteksi mismatch health bar | `85`, `100` |
| `player.is_alive` | Konfirmasi state player | `true` |
| Nilai resource | Deteksi tampilan salah | `"coins": 55` |
| Flag UI aktif | Konfirmasi komponen tampil | `"show_tutorial": false` |
| Build/version | Konteks diff antar build | `"build": "slice-0.22"` |

**Hindari memasukkan:**
- Array besar (inventory penuh, semua enemies) — simpan hanya count
- Data yang selalu berubah setiap frame (posisi real-time)
- Data duplikat yang sudah ada di screenshot

---

## Debugging: Mengapa game_state.json Tidak Terbaca

Jika harness menampilkan fase `developing` padahal sudah implementasi hook:

1. **Cek apakah `_write_game_state()` dipanggil di `--shot` mode**
   ```gdscript
   # SALAH: Dipanggil tanpa cek flag
   func _ready() -> void:
       GameStateWriter.write(_get_game_state())  # selalu jalan, bukan hanya --shot

   # BENAR:
   func _ready() -> void:
       if "--shot" in OS.get_cmdline_user_args():
           await get_tree().process_frame
           GameStateWriter.write(_get_game_state())
   ```

2. **Cek apakah `GameStateWriter` terdaftar sebagai Autoload**
   Di `project.godot` harus ada:
   ```ini
   [autoload]
   GameStateWriter="*res://scripts/GameStateWriter.gd"
   ```

3. **Cek path output benar**
   File ditulis ke `user://shots/game_state.json`.
   Harness mencarinya di folder yang sama dengan PNG output.

4. **Cek timing — tulis terlalu awal**
   ```gdscript
   # SALAH: Tulis sebelum frame pertama
   func _ready() -> void:
       GameStateWriter.write(_get_game_state())  # sistem belum init

   # BENAR: Tunggu minimal 1 frame
   func _ready() -> void:
       if "--shot" in OS.get_cmdline_user_args():
           await get_tree().process_frame
           GameStateWriter.write(_get_game_state())
   ```
