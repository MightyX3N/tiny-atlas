extends Node
## The player's equipment, through the OmniPlay SDK. Runs OmniPlay's own Lua device code
## (lua/bridge.lua: the same devices.lua, bt/win.lua, bt/fake.lua the OmniPlay app uses) in a
## LuaJIT state from the Lua GDExtension addon. On Windows that's WinRT Bluetooth through
## omniplay_ble.dll; with --fake it's OmniPlay's pretend devices.
## Without the addon (or Bluetooth) the game still runs, with the keyboard.

const MODULES := {
	"omniplay": "res://lua/omniplay.lua",
	"devices": "res://lua/devices.lua",
	"settings": "res://lua/settings.lua",
	"lib.json": "res://lua/lib/json.lua",
	"bt.win": "res://lua/bt/win.lua",
	"bt.fake": "res://lua/bt/fake.lua",
	"bridge": "res://lua/bridge.lua",
}

var lua = null             # LuaState (typed loosely so the game runs without the addon)
var bridge = null          # LuaTable
var jcall = null           # LuaFunction: calls a bridge function and returns its result as JSON text
var available := false     # Bluetooth (or pretend devices) works here
var error_text := ""
var fake := false
var time := 0.0
var last := {}             # values() from the last frame
var events: Array = []

func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	fake = args.has("--fake") or OS.get_environment("OMNIPLAY_FAKE") == "1"
	if not ClassDB.class_exists("LuaState"):
		error_text = "The Lua addon isn't loaded"
		print("OmniPlay devices: ", error_text, " (keyboard only)")
		return
	lua = ClassDB.instantiate("LuaState")
	lua.open_libraries(8191) # LUA_ALL_LIBS: base, package, string, table, math, io, os, ffi, jit...
	for name in MODULES:
		var src := FileAccess.get_file_as_string(MODULES[name])
		if src == "":
			push_error("missing Lua module " + name)
			continue
		lua.globals.set("__src", src)
		lua.globals.set("__name", name)
		var r = lua.do_string("package.preload[__name] = assert(loadstring(__src, '@' .. __name))")
		if _is_error(r): push_error("Lua: " + str(r.message))
	lua.globals.set("__src", null)
	var b = lua.do_string("return require('bridge')")
	if _is_error(b) or b == null:
		error_text = str(b.message) if b != null else "bridge didn't load"
		push_error("Lua: " + error_text)
		return
	bridge = b
	# Tables come back as JSON text: the addon's LuaTable.to_dictionary() can hit an unprotected Lua error
	# (it aborted the game), so no Lua table is read from GDScript directly.
	var j = lua.do_string("""
		local json = require('lib.json'); local B = require('bridge')
		return function(fn, ...)
			local ok, r = pcall(B[fn], ...)
			if not ok then return json.encode({ __error = tostring(r) }) end
			if r == nil then return 'null' end
			return json.encode(r)
		end""")
	if _is_error(j) or j == null:
		error_text = "bridge helper didn't load"; bridge = null; return
	jcall = j
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("template"):
		exe_dir = ProjectSettings.globalize_path("res://")
	var save_dir := ProjectSettings.globalize_path("user://")
	var res = _call("init", [fake, OS.get_name(), exe_dir, save_dir])
	if res is Dictionary:
		available = res.get("ok", false) == true
		error_text = str(res.get("err", ""))
	print("OmniPlay devices: ", "pretend devices" if fake else ("Bluetooth ready" if available else "no Bluetooth: " + error_text))

static func _is_error(r) -> bool:
	return r is Object and r != null and r.get_class() == "LuaError"

## Calls a bridge function. Several return values come back as an Array.
func _call(fn: String, args: Array = []):
	if bridge == null: return null
	var r = jcall.invokev([fn] + args)
	if _is_error(r):
		push_error("Lua %s: %s" % [fn, r.message])
		return null
	if r == null: return null
	var v = JSON.parse_string(str(r))
	if v is Dictionary and v.has("__error"):
		push_error("Lua %s: %s" % [fn, v.__error])
		return null
	return v

func _process(dt: float) -> void:
	time += dt
	if bridge == null: return
	_call("update", [minf(dt, 0.1), time])
	var v = _call("values")
	if v is Dictionary: last = v
	var e = _call("take_events")
	if e is Array:
		for x in e: events.append(str(x))

func _table_array(r) -> Array:
	return r if r is Array else []

func scan(on: bool) -> void: _call("scan", [on])
func nearby() -> Array: return _table_array(_call("nearby"))
func connections() -> Array: return _table_array(_call("connections"))
func connect_device(addr: String, dev_name: String) -> void: _call("connect", [addr, dev_name])
func forget(addr: String) -> void: _call("forget", [addr])
func set_grade(pct) -> void: _call("set_grade", [pct])
func allow_hills(on: bool) -> void: _call("allow_hills", [on])
func hills_allowed() -> bool: return bridge == null or _call("hills_allowed") == true
func fake_effort(n: int) -> void: _call("fake_effort", [n])
func walk_factor(pct: float) -> float:
	var r = _call("walk_factor", [pct])
	if r == null: return exp(-3.5 * (absf(pct / 100.0 + 0.05) - 0.05))  # same formula as the SDK
	return float(r)

func value(key: String, fallback = -1.0):
	return last.get(key, fallback)

func connected() -> bool: return last.get("connected", false) == true

func _exit_tree() -> void:
	_call("shutdown")
