extends SceneTree
## Headless test runner for the simulator:
##
##     godot --headless --path simulator --script res://tests/run_tests.gd [-- <filter>...]
##
## Runs every `test_*` method of every `res://tests/test_*.gd` (see `test_case.gd`). With
## filters, only files whose name contains one of them run. Exits 1 if anything failed.

const TESTS_DIR := "res://tests"
const TestCase := preload("res://tests/test_case.gd")

## A runtime script error aborts the test function without the runner noticing; this catches
## them (plain `push_error`s are expected from some tests and don't count).
class ErrorCatcher extends Logger:
	var errors: PackedStringArray = []
	var _lock := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_lock.lock()
		errors.append("script error at %s:%d in %s(): %s" % [file, line, function, rationale if rationale else code])
		_lock.unlock()

	func take() -> PackedStringArray:
		_lock.lock()
		var out := errors
		errors = []
		_lock.unlock()
		return out

var _catcher := ErrorCatcher.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Let the root window settle so tests can add nodes and await frames.
	await process_frame
	OS.add_logger(_catcher)
	var filters := OS.get_cmdline_user_args()
	var files := []
	for f in DirAccess.get_files_at(TESTS_DIR):
		if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
			if filters.is_empty() or Array(filters).any(func(s): return s in f):
				files.append(f)
	files.sort()

	var passed := 0
	var failed: Array[String] = []
	for file in files:
		var script: GDScript = load(TESTS_DIR.path_join(file))
		if script == null or not script.can_instantiate():
			failed.append(file.get_basename())
			print("FAIL %s (does not compile)" % file.get_basename())
			continue
		var names := []
		for m in script.get_script_method_list():
			if m.name.begins_with("test_") and not names.has(m.name):
				names.append(m.name)
		for test_name in names:
			_catcher.take()
			var t: TestCase = script.new()
			t.tree = self
			var id := "%s::%s" % [file.get_basename(), test_name]
			if t.has_method("before_each"):
				await t.before_each()
			await t.call(test_name)
			if t.has_method("after_each"):
				await t.after_each()
			t._free_nodes()
			t.failures.append_array(_catcher.take())
			if t.failures.is_empty():
				passed += 1
				print("PASS %s" % id)
			else:
				failed.append(id)
				print("FAIL %s" % id)
				for msg in t.failures:
					print("     %s" % msg)

	OS.remove_logger(_catcher)
	_remove_tree(TestCase.temp_root())
	print("\n%d passed, %d failed" % [passed, failed.size()])
	for id in failed:
		print("  FAILED %s" % id)
	if files.is_empty():
		printerr("No test files matched %s" % [filters])
	quit(1 if failed or files.is_empty() else 0)


static func _remove_tree(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
