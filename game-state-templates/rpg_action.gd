## rpg_action.gd
## Template game state untuk RPG, Action RPG, roguelite, dan game berbasis combat.
##
## Cocok untuk game dengan: player character, health/mana, inventory, combat,
## quest/objective, level/XP, dan multiple scene/area.
##
## CARA PAKAI:
##   1. Copy ke Autoload (misal: GameTelemetry.gd) atau attach ke node GameManager
##   2. Panggil GameTelemetry._write_game_state() di blok --shot mode
##   3. Sesuaikan setiap referensi (PlayerManager, InventorySystem, QuestManager, dll)
##      dengan nama Autoload/sistem yang ada di project kamu
##   4. Hapus section yang belum diimplementasikan — tidak ada yang wajib

extends Node


func _write_game_state() -> void:
    GameStateWriter.write(_get_game_state())


func _get_game_state() -> Dictionary:
    return {
        "schema_version": 1,
        "timestamp": Time.get_datetime_string_from_system(),
        "scene": get_tree().current_scene.name if get_tree().current_scene else "unknown",

        # --- Player core ---
        # SESUAIKAN: ganti PlayerManager dengan nama Autoload player kamu
        "player": _get_player_state(),

        # --- Combat / battle (hapus jika belum ada) ---
        "combat": _get_combat_state(),

        # --- Inventory (hapus jika belum ada) ---
        "inventory": _get_inventory_state(),

        # --- Quest / objective (hapus jika belum ada) ---
        "quest": _get_quest_state(),

        # --- World / progression (hapus jika belum ada) ---
        "world": _get_world_state(),

        # --- Session ---
        "session": {
            "elapsed_sec": int(Time.get_ticks_msec() / 1000.0),
            "run_number": 0,  # SESUAIKAN: RunManager.run_number
        },
    }


func _get_player_state() -> Dictionary:
    # SESUAIKAN: referensi ke sistem player kamu
    # Contoh jika menggunakan Autoload bernama "Player":
    #   return {
    #       "hp": Player.hp,
    #       "hp_max": Player.hp_max,
    #       "level": Player.level,
    #       "xp": Player.xp,
    #       "xp_next": Player.xp_to_next_level,
    #       "gold": Player.gold,
    #       "position": { "x": Player.global_position.x, "y": Player.global_position.y },
    #       "is_alive": Player.is_alive,
    #   }
    return {
        "hp": 0,         # TODO: Player.hp
        "hp_max": 0,     # TODO: Player.hp_max
        "level": 1,      # TODO: Player.level
        "xp": 0,         # TODO: Player.xp
        "gold": 0,       # TODO: Player.gold
        "is_alive": true, # TODO: Player.is_alive
    }


func _get_combat_state() -> Dictionary:
    # Kosongkan atau hapus jika tidak dalam combat saat screenshot diambil
    # SESUAIKAN: referensi ke CombatManager / BattleManager
    return {
        "in_combat": false,   # TODO: CombatManager.is_active
        "turn": 0,            # TODO: CombatManager.turn_count
        "enemy_count": 0,     # TODO: CombatManager.enemies.size()
        # "enemy_hp": [],     # TODO: array HP musuh
        # "last_action": "",  # TODO: aksi terakhir yang dilakukan
    }


func _get_inventory_state() -> Dictionary:
    # SESUAIKAN: referensi ke InventoryManager
    return {
        "item_count": 0,   # TODO: Inventory.items.size()
        "capacity": 0,     # TODO: Inventory.max_capacity
        # "equipped": [],  # TODO: daftar item yang equipped
        # "hotbar": [],    # TODO: item di hotbar
    }


func _get_quest_state() -> Dictionary:
    # SESUAIKAN: referensi ke QuestManager
    return {
        "active_count": 0,    # TODO: QuestManager.active_quests.size()
        "completed_count": 0, # TODO: QuestManager.completed_quests.size()
        # "active": [],       # TODO: daftar quest aktif dengan progress
    }


func _get_world_state() -> Dictionary:
    # SESUAIKAN: data world/map yang relevan
    return {
        "area": "",          # TODO: nama area saat ini
        "floor": 0,          # TODO: floor/level dungeon (untuk roguelite)
        "enemies_cleared": 0, # TODO: musuh yang sudah dikalahkan di area ini
        # "checkpoints": [], # TODO: checkpoint yang sudah dibuka
    }


# ---------------------------------------------------------------------------
# GameStateWriter utility — tidak perlu dimodifikasi


# ---------------------------------------------------------------------------
# Cara menulis game state:
# Pastikan GameStateWriter.gd sudah terdaftar sebagai Autoload, lalu:
#   GameStateWriter.write(_get_game_state())
# Atau gunakan:
#   GameStateWriter.write_from_node(get_tree().root)
# ---------------------------------------------------------------------------
