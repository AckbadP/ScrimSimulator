class_name RenameDialog
extends ConfirmationDialog
## Asks for a new name: a text field prefilled with the current one; Enter or OK submits.

signal submitted(text: String)

var line_edit: LineEdit


func _init() -> void:
	ok_button_text = "Rename"
	line_edit = LineEdit.new()
	line_edit.custom_minimum_size.x = 320
	add_child(line_edit)
	register_text_enter(line_edit)
	confirmed.connect(func(): submitted.emit(line_edit.text))


## Pops up titled `heading` with `current` selected; `placeholder` shows when the field is empty.
func ask(heading: String, current: String, placeholder := "") -> void:
	title = heading
	line_edit.text = current
	line_edit.placeholder_text = placeholder
	popup_centered()
	line_edit.select_all()
	line_edit.grab_focus()
