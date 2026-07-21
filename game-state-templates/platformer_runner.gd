## platformer_runner.gd
## Template game state untuk Platformer, Runner, dan game berbasis level/checkpoint.
##
## Cocok untuk game dengan: level progression, collectible, lives/health,
## checkpoint, timer, score, dan physics-based movement.
##
## CARA PAKAI:
##   1. Copy ke Autoload atau attach ke GameManager / LevelManager
##   2. Sesuaikan referensi dengan sistem yang ada
##   3. Hapus field yang tidak relevan

extends Node


func _write_game_state() -> void:
    GameStateWriter.write(_get_game_state())


func _get_game_state() -> Dictionary:
    return {
        "schema_version": 1,
        "timestamp": Time.get_datetime_string_from_system(),
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",

        # --- Player state ---
        "player": _get_player_state(),

        # --- Level / stage ---
        "level": _get_level_state(),

        # --- Collectibles ---
        "collectibles": _get_collectible_state(),

        # --- Run stats (untuk runner / roguelite) ---
        "run": _get_run_state(),

        # --- Session ---
        "session": {
            "elapsed_sec": int(Time.get_ticks_msec() / 1000.0),
        },
    }


func _get_player_state() -> Dictionary:
    # SESUAIKAN: referensi ke Player node atau PlayerManager Autoload
    return {
        "hp": 0,             # TODO: Player.hp
        "hp_max": 0,         # TODO: Player.hp_max
        "lives": 3,          # TODO: GameManager.lives
        "is_alive": true,    # TODO: Player.is_alive
        "position": {
            "x": 0.0,        # TODO: Player.global_position.x
            "y": 0.0,        # TODO: Player.global_position.y
        },
        "velocity": {
            "x": 0.0,        # TODO: Player.velocity.x (untuk debug physics)
            "y": 0.0,        # TODO: Player.velocity.y
        },
        "is_grounded": true, # TODO: Player.is_on_floor()
        "power_up": "",      # TODO: Player.active_power_up (jika ada)
    }


func _get_level_state() -> Dictionary:
    # SESUAIKAN: referensi ke LevelManager
    return {
        "world": 1,          # TODO: LevelManager.world_number (contoh: World 1-1)
        "level": 1,          # TODO: LevelManager.level_number
        "checkpoint": 0,     # TODO: CheckpointManager.last_checkpoint_index
        "progress_pct": 0.0, # TODO: persen level yang sudah diselesaikan (0.0-1.0)
        "timer_sec": 0.0,    # TODO: LevelTimer.elapsed (untuk speed-run game)
        "completed": false,  # TODO: apakah level sudah selesai
    }


func _get_collectible_state() -> Dictionary:
    # SESUAIKAN: collectible yang ada di game kamu (koin, bintang, gem, dll)
    return {
        "coins": 0,          # TODO: CollectibleManager.coins
        "coins_total": 0,    # TODO: total koin di level ini
        "stars": 0,          # TODO: bintang yang dikumpulkan
        "secrets_found": 0,  # TODO: secret area yang ditemukan
    }


func _get_run_state() -> Dictionary:
    # Untuk runner / endless game — hapus jika game berbasis level biasa
    return {
        "score": 0,          # TODO: ScoreManager.score
        "high_score": 0,     # TODO: ScoreManager.high_score
        "distance": 0.0,     # TODO: jarak tempuh (untuk endless runner)
        "run_number": 1,     # TODO: berapa kali main (untuk roguelite/retry)
        "combo": 0,          # TODO: combo streak saat ini
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
