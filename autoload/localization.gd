extends Node
## Loads locale/strings.json ({"ru": {KEY: text}, ...}) into the TranslationServer.
## JSON instead of CSV import keeps the pipeline editor-independent (works headless/tests).

const STRINGS_PATH := "res://locale/strings.json"
const DEFAULT_LOCALE := "ru"

var tables: Dictionary = {}


func _ready() -> void:
	_load()
	TranslationServer.set_locale(DEFAULT_LOCALE)


func _load() -> void:
	var f := FileAccess.open(STRINGS_PATH, FileAccess.READ)
	if f == null:
		push_error("Localization: cannot open %s" % STRINGS_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		push_error("Localization: %s is not a JSON object" % STRINGS_PATH)
		return
	tables = parsed
	for locale: String in tables.keys():
		var t := Translation.new()
		t.locale = locale
		var table: Dictionary = tables[locale]
		for key: String in table.keys():
			t.add_message(key, str(table[key]))
		TranslationServer.add_translation(t)


func has_key(key: String, locale: String = DEFAULT_LOCALE) -> bool:
	return tables.has(locale) and (tables[locale] as Dictionary).has(key)


## Translate + format with named placeholders: t("KEY", {"n": 3}) for "… {n} …".
func t(key: String, args: Dictionary = {}) -> String:
	var s := String(TranslationServer.translate(key))
	return s.format(args) if not args.is_empty() else s
