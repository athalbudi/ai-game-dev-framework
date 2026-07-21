## puzzle.gd
## Template game state untuk Puzzle game (match-3, sokoban, word puzzle,
## logic puzzle, physics puzzle, narrative puzzle).
##
## Cocok untuk game dengan: level, board state, move counter, hint system,
## objective tracking, dan solution validation.
##
## CARA PAKAI:
##   1. Copy ke Autoload atau PuzzleManager
##   2. Sesuaikan referensi dengan sistem puzzle yang ada
##   3. Hapus field yang tidak relevan untuk jenis puzzle game kamu

extends Node


func _write_game_state() -> void:
    GameStateWriter.write(_get_game_state())


func _get_game_state() -> Dictionary:
    return {
        "schema_version": 1,
        "timestamp": Time.get_datetime_string_from_system(),
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",

        # --- Level / stage ---
        "level": _get_level_state(),

        # --- Board / puzzle state ---
        "board": _get_board_state(),

        # --- Player progress ---
        "progress": _get_progress_state(),

        # --- Hint system ---
        "hints": _get_hint_state(),

        # --- Session ---
        "session": {
            "elapsed_sec": int(Time.get_ticks_msec() / 1000.0),
            "level_timer_sec": 0.0,  # TODO: LevelTimer.elapsed
        },
    }


func _get_level_state() -> Dictionary:
    # SESUAIKAN: referensi ke LevelManager / PuzzleManager
    return {
        "level_id": "",         # TODO: PuzzleManager.current_level_id
        "level_number": 0,      # TODO: LevelManager.current_number
        "pack": "",             # TODO: nama pack/chapter (misal: "Forest", "Space")
        "is_completed": false,  # TODO: PuzzleManager.is_solved
        "is_failed": false,     # TODO: apakah kondisi gagal sudah tercapai
        "stars_earned": 0,      # TODO: bintang yang diraih (0-3 untuk many puzzle games)
    }


func _get_board_state() -> Dictionary:
    # SESUAIKAN: representasi state puzzle saat ini
    # Ini sangat bervariasi per jenis puzzle — sesuaikan dengan game kamu
    return {
        "width": 0,             # TODO: Board.width (untuk grid-based puzzle)
        "height": 0,            # TODO: Board.height
        "cell_count": 0,        # TODO: jumlah cell aktif
        "filled_count": 0,      # TODO: cell yang sudah terisi (untuk progress %)

        # Untuk match-3:
        # "pieces": [],         # TODO: array tipe piece per cell
        # "combo_active": false,

        # Untuk sokoban/block puzzle:
        # "boxes_on_target": 0, # TODO: jumlah kotak yang sudah di posisi target
        # "boxes_total": 0,

        # Untuk word puzzle:
        # "letters_placed": [], # TODO: huruf yang sudah ditempatkan
        # "words_found": [],    # TODO: kata yang sudah ditemukan
    }


func _get_progress_state() -> Dictionary:
    # SESUAIKAN: tracking progress pemain
    return {
        "moves_used": 0,        # TODO: PuzzleManager.move_count
        "moves_limit": 0,       # TODO: batas gerakan (0 = unlimited)
        "time_limit_sec": 0.0,  # TODO: batas waktu (0 = unlimited)
        "objective_count": 0,   # TODO: jumlah objective di level ini
        "objective_done": 0,    # TODO: objective yang sudah selesai
        "score": 0,             # TODO: skor saat ini
        "best_score": 0,        # TODO: skor terbaik di level ini
    }


func _get_hint_state() -> Dictionary:
    # SESUAIKAN: sistem hint
    return {
        "hints_remaining": 0,   # TODO: HintManager.remaining
        "hints_used": 0,        # TODO: HintManager.used_count
        "hint_active": false,   # TODO: apakah hint sedang ditampilkan
    }


# ---------------------------------------------------------------------------
# GameStateWriter utility


# ---------------------------------------------------------------------------
# Cara menulis game state:
# Pastikan GameStateWriter.gd sudah terdaftar sebagai Autoload, lalu:
#   GameStateWriter.write(_get_game_state())
# Atau gunakan:
#   GameStateWriter.write_from_node(get_tree().root)
# ---------------------------------------------------------------------------
