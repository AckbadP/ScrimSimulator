class_name EventStrip
extends Control
## Thin bar above the timeline slider with a coloured tick per match event, lined up with the
## slider's grabber. Hover a tick for its description; click one to jump to it.

signal mark_pressed(index: int)

## A click or hover this many pixels from a tick counts as on it.
const HIT_PX := 5.0
const TICK_W := 3.0

## Array of { t: float (match time), color: Color, text: String }.
var marks: Array = []
var duration := 0.0
## The slider the ticks line up with (its grabber can't reach the very ends).
var slider: Slider


func _init() -> void:
	custom_minimum_size.y = 12.0
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_marks(new_marks: Array, new_duration: float) -> void:
	marks = new_marks
	duration = new_duration
	queue_redraw()


## Horizontal pixel where match time `t` sits, matching the slider grabber's centre.
func x_of(t: float) -> float:
	var inset := 0.0
	if slider:
		inset = slider.get_theme_icon("grabber").get_width() / 2.0
	var ratio := clampf(t / duration, 0.0, 1.0) if duration > 0.0 else 0.0
	return inset + ratio * (size.x - 2.0 * inset)


## Index of the mark nearest `x` within `HIT_PX`, or -1. Later marks win ties so the tick drawn
## on top is the one picked.
func mark_at(x: float) -> int:
	var best := -1
	var best_d := HIT_PX
	for i in marks.size():
		var d := absf(x_of(marks[i].t) - x)
		if d <= best_d:
			best = i
			best_d = d
	return best


func _draw() -> void:
	for m in marks:
		var x := x_of(m.t)
		draw_rect(Rect2(x - TICK_W / 2.0, 0.0, TICK_W, size.y), m.color)


## Every mark within reach of the cursor, one line each (ticks often overlap).
func _get_tooltip(at_position: Vector2) -> String:
	var lines := PackedStringArray()
	for m in marks:
		if absf(x_of(m.t) - at_position.x) <= HIT_PX:
			lines.append(m.text)
	return "\n".join(lines)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var i := mark_at(event.position.x)
		if i >= 0:
			mark_pressed.emit(i)
			accept_event()
