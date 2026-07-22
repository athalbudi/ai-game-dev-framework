## universal_minimal.gd
## Template game state MINIMAL — cocok untuk semua genre, termasuk prototype.
##
## CARA PAKAI:
##   1. Copy fungsi _write_game_state() dan GameStateWriter ke dalam Autoload atau scene utama
##   2. Panggil _write_game_state() di dalam blok --shot mode kamu
##   3. Tambahkan field sesuai kebutuhan — hapus yang tidak relevan
##
## TIDAK ADA FIELD YANG WAJIB — semua opsional. Framework tetap berjalan meski kosong.
##
## CONTOH pemanggilan di main.gd:
##   func _ready() -> void:
##       if "--shot" in OS.get_cmdline_args():
##           _write_game_state()
##           _shot_tour()

extends Node

# ---------------------------------------------------------------------------
# Fungsi utama — sesuaikan isi sesuai sistem yang sudah ada di game kamu
# ---------------------------------------------------------------------------
func _write_game_state() -> void:
    var state: Dictionary = _get_game_state()
    GameStateWriter.write(state)


func _get_game_state() -> Dictionary:
    return {
        # --- Metadata wajib (jangan hapus) ---
        "schema_version": "1.0",
        "timestamp": Time.get_datetime_string_from_system(),
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",

        # --- Session info (opsional) ---
        # "session": {
        #     "elapsed_sec": int(Time.get_ticks_msec() / 1000.0),
        #     "frame_count": Engine.get_process_frames(),
        # },

        # --- Tambahkan field game kamu di sini ---
        # Contoh:
        # "score": GameManager.score,
        # "level": GameManager.current_level,
    }


# ---------------------------------------------------------------------------
# GameStateWriter — utility class, tidak perlu dimodifikasi
# Tulis ke user://shots/game_state.json


# ---------------------------------------------------------------------------
# Cara menulis game state:
# Pastikan GameStateWriter.gd sudah terdaftar sebagai Autoload, lalu:
#   GameStateWriter.write(_get_game_state())
# Atau gunakan:
#   GameStateWriter.write_from_node(get_tree().root)
# ---------------------------------------------------------------------------
