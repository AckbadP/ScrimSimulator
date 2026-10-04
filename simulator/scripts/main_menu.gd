class_name MainMenu
extends PanelContainer
## Full-screen start menu: pick a match from the `MatchLibrary`, add a new CSV to it, rename or
## remove one. Covers the viewer until a match is chosen.

## The library path of the match to open.
signal match_chosen(path: String)
## "Back to match" pressed: return to the match that is already open.
signal resumed
## A library match was renamed (its file moved from `old_path` to `new_path`).
signal match_renamed(old_path: String, new_path: String)

var list: ItemList
var open_button: Button
var rename_button: Button
var remove_button: Button
var resume_button: Button
var error_label: Label
var empty_label: Label
var add_dialog: FileDialog
var remove_dialog: ConfirmationDialog
var rename_dialog: RenameDialog
## Library entries in `list` order (see `MatchLibrary.list`).
var entries: Array = []


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	panel.bg_color = Color(0.06, 0.07, 0.1)
	add_theme_stylebox_override("panel", panel)

	var center := CenterContainer.new()
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "Scrim Simulator"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Matches"
	subtitle.modulate = Color(1, 1, 1, 0.7)
	box.add_child(subtitle)

	list = ItemList.new()
	list.custom_minimum_size = Vector2(0, 320)
	list.item_activated.connect(func(_i): _open_selected())
	list.item_selected.connect(func(_i): _update_buttons())
	box.add_child(list)

	empty_label = Label.new()
	empty_label.text = "No matches yet — Add match… or drop a *.positions.csv here"
	empty_label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(empty_label)

	error_label = Label.new()
	error_label.modulate = Color(1.0, 0.45, 0.4)
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_label.visible = false
	box.add_child(error_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)

	open_button = Button.new()
	open_button.text = "Open"
	open_button.pressed.connect(_open_selected)
	buttons.add_child(open_button)

	var add_button := Button.new()
	add_button.text = "Add match…"
	add_button.pressed.connect(func(): add_dialog.popup_centered_ratio(0.6))
	buttons.add_child(add_button)

	rename_button = Button.new()
	rename_button.text = "Rename…"
	rename_button.pressed.connect(_ask_rename)
	buttons.add_child(rename_button)

	remove_button = Button.new()
	remove_button.text = "Remove"
	remove_button.pressed.connect(_confirm_remove)
	buttons.add_child(remove_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)

	resume_button = Button.new()
	resume_button.text = "Back to match"
	resume_button.visible = false
	resume_button.pressed.connect(func(): resumed.emit())
	buttons.add_child(resume_button)

	add_dialog = FileDialog.new()
	add_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	add_dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_dialog.filters = PackedStringArray(["*.csv ; CSV files"])
	add_dialog.use_native_dialog = true
	add_dialog.file_selected.connect(add_file)
	add_child(add_dialog)

	remove_dialog = ConfirmationDialog.new()
	remove_dialog.title = "Remove match"
	remove_dialog.ok_button_text = "Remove"
	remove_dialog.confirmed.connect(_remove_selected)
	add_child(remove_dialog)

	rename_dialog = RenameDialog.new()
	rename_dialog.submitted.connect(rename_selected)
	add_child(rename_dialog)

	refresh()


## Reloads the list from the library, keeping the selected match selected.
func refresh() -> void:
	var was := selected_path()
	entries = MatchLibrary.list()
	list.clear()
	for e in entries:
		list.add_item("%s — %s" % [e.name, _fmt_date(e.modified)])
		if e.path == was:
			list.select(list.item_count - 1)
	if not list.is_anything_selected() and list.item_count > 0:
		list.select(0)
	empty_label.visible = entries.is_empty()
	_update_buttons()


## Shows `text` as an error under the list ("" hides it).
func show_error(text: String) -> void:
	error_label.text = text
	error_label.visible = text != ""


## Copies `src` into the library, selects it, and asks for it to be opened.
func add_file(src: String) -> void:
	var path := MatchLibrary.add(src)
	if path == "":
		show_error("Failed to add %s" % src.get_file())
		return
	show_error("")
	refresh()
	for i in entries.size():
		if entries[i].path == path:
			list.select(i)
	match_chosen.emit(path)


## The selected match's library path, or "".
func selected_path() -> String:
	if list == null:
		return ""
	var sel := list.get_selected_items()
	return entries[sel[0]].path if not sel.is_empty() and sel[0] < entries.size() else ""


func _open_selected() -> void:
	var path := selected_path()
	if path != "":
		show_error("")
		match_chosen.emit(path)


func _confirm_remove() -> void:
	var sel := list.get_selected_items()
	if sel.is_empty():
		return
	remove_dialog.dialog_text = "Remove %s from the match list?\nThe copied CSV is deleted; the original file is not touched." % entries[sel[0]].name
	remove_dialog.popup_centered()


func _remove_selected() -> void:
	var path := selected_path()
	if path == "":
		return
	MatchLibrary.remove(path)
	refresh()


func _ask_rename() -> void:
	var sel := list.get_selected_items()
	if not sel.is_empty():
		rename_dialog.ask("Rename match", entries[sel[0]].name)


## Renames the selected match to `new_name`, keeping it selected.
func rename_selected(new_name: String) -> void:
	var old := selected_path()
	if old == "":
		return
	var path := MatchLibrary.rename(old, new_name)
	if path == "":
		show_error("Cannot rename to \"%s\": the name is empty or already taken" % new_name.strip_edges())
		return
	show_error("")
	refresh()
	for i in entries.size():
		if entries[i].path == path:
			list.select(i)
	_update_buttons()
	if path != old:
		match_renamed.emit(old, path)


func _update_buttons() -> void:
	var any := list.is_anything_selected()
	open_button.disabled = not any
	rename_button.disabled = not any
	remove_button.disabled = not any


## Unix time -> local "yyyy-mm-dd hh:mm".
static func _fmt_date(unix: int) -> String:
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_datetime_string_from_unix_time(unix + bias * 60, true).left(16)
