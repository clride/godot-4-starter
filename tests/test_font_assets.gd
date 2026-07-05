extends SceneTree
## Validation tests for the font assets added to BaseClasses/Assets/Fonts
## (Blaec, DigiTech, ErraticCursive font families).
##
## This project does not currently ship a unit-testing addon (e.g. GUT), so
## this is a minimal, dependency-free SceneTree runner that exercises the
## same GDScript APIs (FileAccess, ConfigFile) that Godot itself uses to
## resolve and import these resources.
##
## Run headlessly with:
##   godot --headless --script res://tests/test_font_assets.gd
##
## Every "test_" method is discovered automatically and executed. Failures
## are collected (rather than raised) so a single run reports every problem
## found instead of stopping at the first one. The script exits with code 0
## when all assertions pass and 1 otherwise, which makes it usable in CI.

const FONTS_ROOT := "res://BaseClasses/Assets/Fonts/"

## (family_dir, base_name) pairs for every font file added in this PR.
const FONT_FILES := [
	["Blaec", "Blaec-Regular"],
	["Blaec", "Blaec-Italic"],
	["DigiTech", "DigitTech7-Regular"],
	["DigiTech", "DigitTech7-Italic"],
	["DigiTech", "DigitTech9-Regular"],
	["DigiTech", "DigitTech9-Italic"],
	["DigiTech", "DigitTech14-Regular"],
	["DigiTech", "DigitTech14-Italic"],
	["DigiTech", "DigitTech16-Regular"],
	["DigiTech", "DigitTech16-Italic"],
	["ErraticCursive", "ErraticCursive-Regular"],
	["ErraticCursive", "ErraticCursive-Italic"],
]

## Font family folders that ship a CC0 License.txt alongside their fonts.
const LICENSE_DIRS := ["Blaec", "DigiTech", "ErraticCursive"]

## TrueType (sfnt 1.0) files begin with the 4-byte signature 0x00 0x01 0x00 0x00.
const TTF_MAGIC := PackedByteArray([0x00, 0x01, 0x00, 0x00])

const REQUIRED_IMPORT_PARAM_KEYS := [
	"antialiasing",
	"generate_mipmaps",
	"disable_embedded_bitmaps",
	"multichannel_signed_distance_field",
	"allow_system_fallback",
	"hinting",
	"subpixel_positioning",
	"compress",
]

var _errors: Array[String] = []
var _tests_run := 0


func _initialize() -> void:
	for method in get_method_list():
		var method_name: String = method.name
		if method_name.begins_with("test_"):
			_run_test(method_name, Callable(self, method_name))

	_report()
	quit(0 if _errors.is_empty() else 1)


func _run_test(test_name: String, fn: Callable) -> void:
	_tests_run += 1
	var before := _errors.size()
	fn.call()
	if _errors.size() == before:
		print("[PASS] %s" % test_name)
	else:
		print("[FAIL] %s" % test_name)


func _report() -> void:
	print("\n%d test(s) run, %d failure(s)." % [_tests_run, _errors.size()])
	for e in _errors:
		printerr(" - %s" % e)


func _fail(message: String) -> void:
	_errors.append(message)


func _assert_true(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _assert_eq(actual, expected, message: String) -> void:
	if actual != expected:
		_fail("%s (expected %s, got %s)" % [message, str(expected), str(actual)])


func _font_ttf_path(entry: Array) -> String:
	return "%s%s/%s.ttf" % [FONTS_ROOT, entry[0], entry[1]]


func _font_import_path(entry: Array) -> String:
	return "%s%s/%s.ttf.import" % [FONTS_ROOT, entry[0], entry[1]]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_font_files_exist_and_are_non_empty() -> void:
	for entry in FONT_FILES:
		var path := _font_ttf_path(entry)
		_assert_true(FileAccess.file_exists(path), "Expected font file to exist: %s" % path)
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		_assert_true(f != null, "Could not open font file: %s" % path)
		if f != null:
			_assert_true(f.get_length() > 0, "Font file is empty: %s" % path)
			f.close()


func test_font_files_have_valid_ttf_signature() -> void:
	for entry in FONT_FILES:
		var path := _font_ttf_path(entry)
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var header := f.get_buffer(4)
		f.close()
		_assert_eq(header, TTF_MAGIC, "Unexpected TTF signature for %s" % path)


func test_import_files_exist_for_every_font() -> void:
	for entry in FONT_FILES:
		var path := _font_import_path(entry)
		_assert_true(FileAccess.file_exists(path), "Expected .import file to exist: %s" % path)


func test_import_files_declare_correct_remap_section() -> void:
	for entry in FONT_FILES:
		var import_path := _font_import_path(entry)
		var cf := ConfigFile.new()
		var err := cf.load(import_path)
		_assert_eq(err, OK, "Failed to parse .import file: %s" % import_path)
		if err != OK:
			continue

		_assert_eq(
			cf.get_value("remap", "importer", ""),
			"font_data_dynamic",
			"Unexpected importer for %s" % import_path
		)
		_assert_eq(
			cf.get_value("remap", "type", ""),
			"FontFile",
			"Unexpected resource type for %s" % import_path
		)

		var uid: String = cf.get_value("remap", "uid", "")
		_assert_true(uid.begins_with("uid://"), "Missing/invalid uid for %s" % import_path)


func test_import_files_declare_correct_source_file() -> void:
	for entry in FONT_FILES:
		var family: String = entry[0]
		var base_name: String = entry[1]
		var import_path := _font_import_path(entry)

		var cf := ConfigFile.new()
		if cf.load(import_path) != OK:
			continue

		var expected_source := "%s%s/%s.ttf" % [FONTS_ROOT, family, base_name]
		var source_file: String = cf.get_value("deps", "source_file", "")
		_assert_eq(
			source_file,
			expected_source,
			"source_file mismatch in %s (possible copy/paste error between fonts)" % import_path
		)

		var dest_files: Array = cf.get_value("deps", "dest_files", [])
		_assert_eq(dest_files.size(), 1, "Expected exactly one dest file for %s" % import_path)
		if dest_files.size() != 1:
			continue

		var dest: String = dest_files[0]
		_assert_true(
			dest.begins_with("res://.godot/imported/%s.ttf-" % base_name),
			"dest_files entry does not match its own font name for %s (got %s)" % [import_path, dest]
		)
		_assert_true(
			dest.ends_with(".fontdata"),
			"dest_files entry does not end in .fontdata for %s" % import_path
		)


func test_import_files_have_expected_params() -> void:
	for entry in FONT_FILES:
		var import_path := _font_import_path(entry)
		var cf := ConfigFile.new()
		if cf.load(import_path) != OK:
			continue
		for key in REQUIRED_IMPORT_PARAM_KEYS:
			_assert_true(
				cf.has_section_key("params", key),
				"Missing params/%s in %s" % [key, import_path]
			)


func test_import_uids_are_unique() -> void:
	var seen: Dictionary = {}
	for entry in FONT_FILES:
		var import_path := _font_import_path(entry)
		var cf := ConfigFile.new()
		if cf.load(import_path) != OK:
			continue
		var uid: String = cf.get_value("remap", "uid", "")
		if uid.is_empty():
			continue
		_assert_true(
			not seen.has(uid),
			"Duplicate uid %s reused by %s and %s" % [uid, seen.get(uid, ""), import_path]
		)
		seen[uid] = import_path


func test_license_files_exist_and_reference_cc0() -> void:
	for dir_name in LICENSE_DIRS:
		var path := "%s%s/License.txt" % [FONTS_ROOT, dir_name]
		_assert_true(FileAccess.file_exists(path), "Expected License.txt to exist for %s" % dir_name)
		if not FileAccess.file_exists(path):
			continue

		var f := FileAccess.open(path, FileAccess.READ)
		var text := f.get_as_text()
		f.close()

		_assert_true(text.length() > 0, "License.txt is empty for %s" % dir_name)
		_assert_true(
			text.findn("CC0") != -1 or text.findn("Creative Commons") != -1,
			"License.txt for %s does not mention CC0/Creative Commons" % dir_name
		)


func test_missing_font_is_reported_as_absent() -> void:
	# Negative/regression check for the validation logic itself: a font name
	# that is not part of this PR must not be reported as present. This
	# guards against a checker that silently passes regardless of input.
	var bogus_path := "%sBlaec/Blaec-NonExistentWeight.ttf" % FONTS_ROOT
	_assert_true(
		not FileAccess.file_exists(bogus_path),
		"Sanity check failed: unexpectedly found %s" % bogus_path
	)