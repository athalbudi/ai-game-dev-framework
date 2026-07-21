## strategy_resource.gd
## Template game state untuk Strategy, Tower Defense, Idle, dan game berbasis resource.
##
## Cocok untuk game dengan: resource management, unit/building, economy,
## turn-based atau real-time strategy, idle progression, wave defense.
##
## CARA PAKAI:
##   1. Copy ke Autoload atau GameManager
##   2. Sesuaikan nama Autoload (ResourceManager, UnitManager, EconomySystem, dll)
##   3. Hapus section yang belum ada

extends Node


func _write_game_state() -> void:
    GameStateWriter.write(_get_game_state())


func _get_game_state() -> Dictionary:
    return {
        "schema_version": 1,
        "timestamp": Time.get_datetime_string_from_system(),
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",

        # --- Resources (wajib untuk genre ini) ---
        "resources": _get_resource_state(),

        # --- Units / buildings ---
        "units": _get_unit_state(),

        # --- Economy / progression ---
        "economy": _get_economy_state(),

        # --- Wave / combat (untuk tower defense / wave-based) ---
        "wave": _get_wave_state(),

        # --- Turn (untuk turn-based strategy) ---
        "turn": _get_turn_state(),

        # --- Session ---
        "session": {
            "elapsed_sec": int(Time.get_ticks_msec() / 1000.0),
            "game_speed": 1.0,  # TODO: GameManager.time_scale
        },
    }


func _get_resource_state() -> Dictionary:
    # SESUAIKAN: ganti dengan ResourceManager atau Dictionary resource game kamu
    # Contoh game dengan oil, wood, stone:
    #   return {
    #       "oil":   ResourceManager.get("oil"),
    #       "wood":  ResourceManager.get("wood"),
    #       "stone": ResourceManager.get("stone"),
    #       "pop":   ResourceManager.get("population"),
    #       "pop_cap": ResourceManager.get("population_cap"),
    #   }
    return {
        # "resource_name": current_value,  # TODO: isi resource yang ada
    }


func _get_unit_state() -> Dictionary:
    # SESUAIKAN: jumlah unit per tipe
    return {
        "total": 0,          # TODO: UnitManager.all_units.size()
        "idle": 0,           # TODO: unit yang tidak melakukan tugas
        "in_combat": 0,      # TODO: unit yang sedang dalam combat
        # "by_type": {},     # TODO: breakdown per tipe unit
    }


func _get_economy_state() -> Dictionary:
    # SESUAIKAN: ekonomi game (score, income, tech level, dll)
    return {
        "score": 0,          # TODO: GameManager.score
        "income_rate": 0.0,  # TODO: resource per detik / per turn
        "tech_level": 0,     # TODO: level teknologi (jika ada research tree)
        # "upgrades": [],    # TODO: upgrade yang sudah dibeli
    }


func _get_wave_state() -> Dictionary:
    # Khusus tower defense / wave-based game — hapus jika tidak relevan
    return {
        "wave_number": 0,    # TODO: WaveManager.current_wave
        "wave_total": 0,     # TODO: WaveManager.total_waves
        "enemies_alive": 0,  # TODO: EnemyManager.alive_count
        "lives": 0,          # TODO: GameManager.lives
        "in_wave": false,    # TODO: WaveManager.is_active
    }


func _get_turn_state() -> Dictionary:
    # Khusus turn-based strategy — hapus jika real-time
    return {
        "turn_number": 0,    # TODO: TurnManager.turn
        "current_player": "", # TODO: TurnManager.active_player (multiplayer)
        "phase": "",         # TODO: TurnManager.phase (move/attack/build/dll)
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
