class_name OpaquePopup
extends PopupPanel
## PopupPanel with a solid background (the default theme's panel is 60% transparent, letting the
## scene show through).


func _init() -> void:
	var panel := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	panel.bg_color.a = 1.0
	add_theme_stylebox_override("panel", panel)
