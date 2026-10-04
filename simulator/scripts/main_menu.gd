class_name MainMenu
extends PanelContainer
## Full-screen start menu: pick a match from the `MatchLibrary`, add a new CSV to it, rename or
## remove one, attach audio or combat logs (EVE gamelogs) to one (right-click for all of these). Covers the viewer until a
## match is chosen.

## The library path of the match to open.
signal match_chosen(path: String)
## "Back to match" pressed: return to the match that is already open.
signal resumed
## A library match was renamed (its file moved from `old_path` to `new_path`).
signal match_renamed(old_path: String, new_path: String)
## Library match `path` got, lost or replaced its audio file.
signal audio_changed(path: String)
## Library match `path` got or lost combat logs.
signal logs_changed(path: String)

enum MenuItem { ADD_AUDIO, REMOVE_AUDIO, ADD_LOGS, REMOVE_LOGS, RENAME, REMOVE }

## Badge on matches with audio: a speaker.
const AUDIO_ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M2 6h3l4-3.5v11L5 10H2z" fill="#8fc3ff"/>
<path d="M11 5.5a3.5 3.5 0 0 1 0 5M12.8 3.5a6 6 0 0 1 0 9" stroke="#8fc3ff" stroke-width="1.4" fill="none" stroke-linecap="round"/>
</svg>"""

var list: ItemList
var open_button: Button
var rename_button: Button
var remove_button: Button
var audio_button: Button
var resume_button: Button
var error_label: Label
var empty_label: Label
var add_dialog: FileDialog
var remove_dialog: ConfirmationDialog
var rename_dialog: RenameDialog
var audio_dialog: FileDialog
var logs_dialog: FileDialog
## Right-click menu of a match (`MenuItem` ids).
var context_menu: PopupMenu
var audio_icon: Texture2D
## Same size as `audio_icon`, for matches without audio so names stay aligned.
var blank_icon: Texture2D
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
	list.item_clicked.connect(_on_item_clicked)
	list.allow_rmb_select = true
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

	audio_button = Button.new()
	audio_button.text = "Add audio…"
	audio_button.tooltip_text = "Attach an audio file (ogg, mp3, wav) that starts with the match data"
	audio_button.pressed.connect(_ask_audio)
	buttons.add_child(audio_button)

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

	audio_dialog = FileDialog.new()
	audio_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	audio_dialog.access = FileDialog.ACCESS_FILESYSTEM
	audio_dialog.filters = PackedStringArray(["*.ogg, *.mp3, *.wav ; Audio files"])
	audio_dialog.use_native_dialog = true
	audio_dialog.file_selected.connect(add_audio)
	add_child(audio_dialog)

	logs_dialog = FileDialog.new()
	logs_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	logs_dialog.access = FileDialog.ACCESS_FILESYSTEM
	logs_dialog.filters = PackedStringArray(["*.txt ; EVE gamelogs"])
	logs_dialog.use_native_dialog = true
	logs_dialog.files_selected.connect(add_logs)
	add_child(logs_dialog)

	context_menu = PopupMenu.new()
	context_menu.id_pressed.connect(_on_context_item)
	add_child(context_menu)

	var img := Image.new()
	img.load_svg_from_string(AUDIO_ICON_SVG)
	audio_icon = ImageTexture.create_from_image(img)
	var blank := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	blank_icon = ImageTexture.create_from_image(blank)

	refresh()


## Reloads the list from the library, keeping the selected match selected.
func refresh() -> void:
	var was := selected_path()
	entries = MatchLibrary.list()
	list.clear()
	for e in entries:
		list.add_item("%s — %s" % [e.name, _fmt_date(e.modified)], audio_icon if e.audio else blank_icon)
		var notes := []
		if e.audio:
			notes.append("Has audio")
		var logs := MatchLibrary.log_paths(e.path).size()
		if logs > 0:
			notes.append("%d combat log%s" % [logs, "" if logs == 1 else "s"])
		if not notes.is_empty():
			list.set_item_tooltip(list.item_count - 1, "\n".join(notes))
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


## Copies audio file `src` into the library as the selected match's audio.
func add_audio(src: String) -> void:
	var path := selected_path()
	if path == "":
		return
	if MatchLibrary.set_audio(path, src) == "":
		show_error("Failed to add audio %s — use an ogg, mp3 or wav file" % src.get_file())
		return
	show_error("")
	refresh()
	audio_changed.emit(path)


## Saves the parts of EVE gamelogs `srcs` logged during the selected match as its combat logs
## (`MatchLibrary.add_log`). Each must be a gamelog with combat during the match, which needs a
## CSV with EVE times; the others are skipped and named in the error line.
func add_logs(srcs: PackedStringArray) -> void:
	var path := selected_path()
	if path == "":
		return
	var data := MatchData.load_csv(path, {}, 0.0, true)
	if data == null or not data.has_eve_time():
		show_error("Can't add combat logs: this match has no EVE times (make its CSV with --chat-log or --t0)")
		return
	var failed := []
	for src in srcs:
		if MatchLibrary.add_log(path, src, data) == "":
			failed.append(src.get_file())
	show_error("" if failed.is_empty() else "Not added (not a gamelog, or no combat during this match): %s" % ", ".join(failed))
	refresh()
	if failed.size() < srcs.size():
		logs_changed.emit(path)


## Deletes the selected match's combat logs.
func remove_logs_selected() -> void:
	var path := selected_path()
	if path == "" or MatchLibrary.log_paths(path).is_empty():
		return
	MatchLibrary.remove_logs(path)
	refresh()
	logs_changed.emit(path)


## Deletes the selected match's audio file.
func remove_audio_selected() -> void:
	var path := selected_path()
	if path == "" or MatchLibrary.audio_path(path) == "":
		return
	MatchLibrary.remove_audio(path)
	refresh()
	audio_changed.emit(path)


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


func _ask_audio() -> void:
	if selected_path() != "":
		audio_dialog.popup_centered_ratio(0.6)


## Right-click: select the match and show its menu at the mouse.
func _on_item_clicked(index: int, at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	list.select(index)
	_update_buttons()
	open_context_menu(list.get_screen_position() + at)


## Shows the selected match's right-click menu at screen position `at`.
func open_context_menu(at: Vector2) -> void:
	var path := selected_path()
	if path == "":
		return
	var has_audio := MatchLibrary.audio_path(path) != ""
	context_menu.clear()
	context_menu.add_item("Replace audio…" if has_audio else "Add audio…", MenuItem.ADD_AUDIO)
	context_menu.add_item("Remove audio", MenuItem.REMOVE_AUDIO)
	context_menu.set_item_disabled(context_menu.get_item_index(MenuItem.REMOVE_AUDIO), not has_audio)
	context_menu.add_item("Add combat logs…", MenuItem.ADD_LOGS)
	context_menu.add_item("Remove combat logs", MenuItem.REMOVE_LOGS)
	context_menu.set_item_disabled(context_menu.get_item_index(MenuItem.REMOVE_LOGS),
		MatchLibrary.log_paths(path).is_empty())
	context_menu.add_separator()
	context_menu.add_item("Rename…", MenuItem.RENAME)
	context_menu.add_item("Remove match…", MenuItem.REMOVE)
	context_menu.reset_size()
	context_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _on_context_item(id: int) -> void:
	match id:
		MenuItem.ADD_AUDIO:
			_ask_audio()
		MenuItem.REMOVE_AUDIO:
			remove_audio_selected()
		MenuItem.ADD_LOGS:
			if selected_path() != "":
				logs_dialog.popup_centered_ratio(0.6)
		MenuItem.REMOVE_LOGS:
			remove_logs_selected()
		MenuItem.RENAME:
			_ask_rename()
		MenuItem.REMOVE:
			_confirm_remove()


func _confirm_remove() -> void:
	var sel := list.get_selected_items()
	if sel.is_empty():
		return
	remove_dialog.dialog_text = "Remove %s from the match list?\nThe copied CSV (and its audio and combat logs) is deleted; the original files are not touched." % entries[sel[0]].name
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
	audio_button.disabled = not any
	audio_button.text = "Replace audio…" if any and MatchLibrary.audio_path(selected_path()) != "" else "Add audio…"


## Unix time -> local "yyyy-mm-dd hh:mm".
static func _fmt_date(unix: int) -> String:
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_datetime_string_from_unix_time(unix + bias * 60, true).left(16)
