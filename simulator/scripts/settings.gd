class_name Settings
extends RefCounted
## Persistent user settings in `user://settings.cfg`.

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"sde/auto_update": true,
}

static var _cfg: ConfigFile


static func get_value(key: String) -> Variant:
	_load()
	var parts := key.split("/", true, 1)
	return _cfg.get_value(parts[0], parts[1], DEFAULTS.get(key))


static func set_value(key: String, value: Variant) -> void:
	_load()
	var parts := key.split("/", true, 1)
	_cfg.set_value(parts[0], parts[1], value)
	var err := _cfg.save(PATH)
	if err != OK:
		push_error("Cannot save %s: %s" % [PATH, error_string(err)])


static func _load() -> void:
	if _cfg != null:
		return
	_cfg = ConfigFile.new()
	_cfg.load(PATH)  # Missing file is fine: defaults apply.
