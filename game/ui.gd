class_name GameUI
extends CanvasLayer
## Everything on screen: the riding HUD, messages, and the menus (start, devices, kit & bike, pause, finish).
## Built in code, sized to stay readable.

signal start_pressed
signal devices_pressed
signal quit_pressed
signal back_pressed
signal resume_pressed
signal menu_pressed
signal again_pressed
signal kit_pressed
signal kit_chosen(kind: String, id: String)
signal connect_pressed(addr: String, name: String)
signal forget_pressed(addr: String)
signal hills_toggled(on: bool)

const BG := Color(0.08, 0.1, 0.16, 0.78)
const ACCENT := Color(1.0, 0.72, 0.25)

var theme_main := Theme.new()
var hud: Control
var speed_l: Label
var cad_l: Label
var pow_l: Label
var hr_l: Label
var dist_l: Label
var grade_l: Label
var dev_l: Label
var msg_l: Label
var msg_t := 0.0
var menu: Control
var route_l: Label
var menu_status: Label
var devices: Control
var dev_list: VBoxContainer
var near_list: VBoxContainer
var live_l: Label
var hills_cb: CheckBox
var pause: Control
var finish: Control
var finish_l: Label
var loading: Label
var kits_box: Control
var kits_list: VBoxContainer

func _ready() -> void:
	theme_main.default_font_size = 22
	var sb := StyleBoxFlat.new(); sb.bg_color = BG; sb.set_corner_radius_all(14)
	sb.content_margin_left = 18; sb.content_margin_right = 18; sb.content_margin_top = 12; sb.content_margin_bottom = 12
	theme_main.set_stylebox("panel", "PanelContainer", sb)
	var bn := StyleBoxFlat.new(); bn.bg_color = Color(0.2, 0.26, 0.38); bn.set_corner_radius_all(10)
	bn.content_margin_left = 22; bn.content_margin_right = 22; bn.content_margin_top = 10; bn.content_margin_bottom = 10
	var bh := bn.duplicate(); bh.bg_color = Color(0.28, 0.36, 0.52)
	var bp := bn.duplicate(); bp.bg_color = ACCENT.darkened(0.2)
	theme_main.set_stylebox("normal", "Button", bn); theme_main.set_stylebox("hover", "Button", bh)
	theme_main.set_stylebox("pressed", "Button", bp); theme_main.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme_main.set_font_size("font_size", "Button", 24)
	theme_main.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.85))
	theme_main.set_constant("outline_size", "Label", 4)
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.theme = theme_main
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_hud(root)
	_build_menu(root)
	_build_devices(root)
	_build_pause(root)
	_build_finish(root)
	_build_kits(root)
	loading = _label(root, "Loading...", 40)
	loading.set_anchors_preset(Control.PRESET_CENTER)
	loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading.position = Vector2(-300, -30); loading.size = Vector2(600, 60)
	loading.visible = false
	show_only("")

func _label(parent: Node, text: String, size := 22, col := Color.WHITE) -> Label:
	var l := Label.new(); l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l

func _panel(parent: Node) -> PanelContainer:
	var p := PanelContainer.new(); parent.add_child(p); return p

func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new(); b.text = text; b.pressed.connect(cb); parent.add_child(b); return b

# ---------- riding HUD ----------

func _build_hud(root: Control) -> void:
	hud = Control.new(); hud.set_anchors_preset(Control.PRESET_FULL_RECT); hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud)
	var left := _panel(hud); left.position = Vector2(24, 24)
	var lv := VBoxContainer.new(); lv.add_theme_constant_override("separation", 2); left.add_child(lv)
	speed_l = _label(lv, "0.0 km/h", 40)
	cad_l = _label(lv, "-- rpm", 26)
	pow_l = _label(lv, "-- W", 22, Color(0.85, 0.9, 1.0))
	hr_l = _label(lv, "-- bpm", 22, Color(1.0, 0.6, 0.6))
	# top right, under the keyboard help
	var right := _panel(hud); right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	right.offset_left = -300; right.offset_right = -24; right.offset_top = 130
	right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var rv := VBoxContainer.new(); right.add_child(rv)
	dist_l = _label(rv, "0.0 / 0.0 km", 28)
	grade_l = _label(rv, "0.0 %", 30)
	dev_l = _label(hud, "", 18, Color(0.85, 0.9, 1.0))
	dev_l.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); dev_l.position = Vector2(28, -160)
	msg_l = _label(hud, "", 48, ACCENT)
	msg_l.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE); msg_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg_l.offset_top = 150; msg_l.offset_bottom = 220
	msg_l.add_theme_constant_override("outline_size", 8)
func show_message(text: String, col := ACCENT, secs := 2.2) -> void:
	msg_l.text = text; msg_l.add_theme_color_override("font_color", col); msg_t = secs

func _process(dt: float) -> void:
	if msg_t > 0.0:
		msg_t -= dt
		msg_l.modulate.a = clampf(msg_t / 0.4, 0.0, 1.0)

func set_stats(speed_kmh: float, cadence: float, cad_unit: String, power: float, hr: float) -> void:
	speed_l.text = "%.1f km/h" % speed_kmh
	cad_l.text = ("%d %s" % [int(round(cadence)), cad_unit]) if cadence >= 0.0 else "-- " + cad_unit
	pow_l.text = ("%d W" % int(power)) if power >= 0.0 else "-- W"
	hr_l.text = ("%d bpm" % int(hr)) if hr > 0.0 else "-- bpm"

func set_progress(d: float, total: float, grade: float) -> void:
	dist_l.text = "%.2f / %.1f km" % [d / 1000.0, total / 1000.0]
	var arrow := "▲" if grade > 0.5 else ("▼" if grade < -0.5 else "▶")
	grade_l.text = "%s %.1f %%" % [arrow, grade]
	var col := Color(1, 0.55, 0.35) if grade > 4.0 else (Color(1, 0.85, 0.4) if grade > 1.0 else (Color(0.5, 0.85, 1.0) if grade < -1.0 else Color.WHITE))
	grade_l.add_theme_color_override("font_color", col)

# ---------- menus ----------

func _center_panel(root: Control, w: float) -> VBoxContainer:
	var holder := CenterContainer.new(); holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(holder)
	var p := _panel(holder); p.custom_minimum_size = Vector2(w, 0)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 14); p.add_child(v)
	holder.set_meta("box", v)
	return v

func _build_menu(root: Control) -> void:
	var v := _center_panel(root, 620)
	menu = v.get_parent().get_parent()
	var t := _label(v, "VoxTrainer", 52, ACCENT); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var s := _label(v, "Ride a real route, built from OpenStreetMap in 10 cm voxels", 20, Color(0.8, 0.85, 0.95))
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	route_l = _label(v, "", 24); route_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button(v, "Start riding", func(): start_pressed.emit())
	_button(v, "Connect devices", func(): devices_pressed.emit())
	_button(v, "Kit & bike", func(): kit_pressed.emit())
	_button(v, "Quit", func(): quit_pressed.emit())
	menu_status = _label(v, "", 18, Color(0.8, 0.85, 0.95)); menu_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _build_devices(root: Control) -> void:
	var v := _center_panel(root, 860)
	devices = v.get_parent().get_parent()
	_label(v, "Devices", 40, ACCENT)
	_label(v, "Turn your bike, walking pad, sensor or heart-rate strap on, then pick it below.", 20, Color(0.85, 0.9, 1.0))
	_label(v, "Connected", 24)
	dev_list = VBoxContainer.new(); v.add_child(dev_list)
	_label(v, "Nearby", 24)
	near_list = VBoxContainer.new(); v.add_child(near_list)
	live_l = _label(v, "", 22, Color(0.7, 1.0, 0.75))
	hills_cb = CheckBox.new(); hills_cb.text = "Hills change the bike's resistance"; hills_cb.button_pressed = true
	hills_cb.toggled.connect(func(on): hills_toggled.emit(on)); v.add_child(hills_cb)
	_button(v, "Back", func(): back_pressed.emit())

func fill_devices(conns: Array, near: Array, live: String, note: String) -> void:
	for c in dev_list.get_children(): c.queue_free()
	for c in near_list.get_children(): c.queue_free()
	if conns.is_empty(): _label(dev_list, "  nothing yet", 20, Color(0.7, 0.75, 0.85))
	for c in conns:
		var h := HBoxContainer.new(); dev_list.add_child(h)
		var st: String = c.state
		var col := Color(0.5, 1, 0.6) if st == "connected" else (Color(1, 0.85, 0.4) if st in ["connecting", "exploring", "reconnecting"] else Color(1, 0.55, 0.5))
		var l := _label(h, "%s  -  %s  -  %s" % [c.name, c.label, st], 20, col); l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if c.hint != "": l.text += "  (" + c.hint + ")"
		var addr: String = c.addr
		_button(h, "Forget", func(): forget_pressed.emit(addr))
	if near.is_empty(): _label(near_list, "  " + (note if note != "" else "looking..."), 20, Color(0.7, 0.75, 0.85))
	for d in near:
		var h := HBoxContainer.new(); near_list.add_child(h)
		var l := _label(h, "%s   (%d dBm)" % [d.name, int(d.rssi)], 20); l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var addr: String = d.addr; var nm: String = d.name
		_button(h, "Connect", func(): connect_pressed.emit(addr, nm))
	live_l.text = live

func _build_pause(root: Control) -> void:
	var v := _center_panel(root, 420)
	pause = v.get_parent().get_parent()
	var t := _label(v, "Paused", 40, ACCENT); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button(v, "Keep riding", func(): resume_pressed.emit())
	_button(v, "Back to the menu", func(): menu_pressed.emit())

## Kit & bike: a list on the left so the rider stays visible on the right
func _build_kits(root: Control) -> void:
	var p := _panel(root)
	p.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	p.offset_left = 24; p.offset_top = 24; p.offset_bottom = -24; p.offset_right = 24 + 520
	var sc := ScrollContainer.new(); sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p.add_child(sc)
	kits_list = VBoxContainer.new(); kits_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kits_list.add_theme_constant_override("separation", 8)
	sc.add_child(kits_list)
	kits_box = p

func fill_kits(k: Kits) -> void:
	for c in kits_list.get_children(): c.queue_free()
	_label(kits_list, "Kit & bike", 40, ACCENT)
	_label(kits_list, "%.1f km ridden  ·  %d rides finished" % [k.total_km, k.rides], 20, Color(0.8, 0.85, 0.95))
	for section in [["Kits", Kits.KITS, "kit", k.kit_id], ["Bike paint", Kits.PAINTS, "paint", k.paint_id]]:
		_label(kits_list, section[0], 28)
		for it in section[1]:
			var id: String = it.id
			var kind: String = section[2]
			if k.is_unlocked(it):
				var b := _button(kits_list, ("✓  " if id == section[3] else "     ") + it.name, func(): kit_chosen.emit(kind, id))
				b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			else:
				var b := _button(kits_list, "🔒  %s\n      %s" % [it.name, k.requirement(it)], func(): pass)
				b.disabled = true; b.alignment = HORIZONTAL_ALIGNMENT_LEFT
				b.add_theme_font_size_override("font_size", 19)
	_button(kits_list, "Back", func(): back_pressed.emit())

func _build_finish(root: Control) -> void:
	var v := _center_panel(root, 560)
	finish = v.get_parent().get_parent()
	var t := _label(v, "Finished!", 52, ACCENT); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	finish_l = _label(v, "", 24)
	_button(v, "Ride again", func(): again_pressed.emit())
	_button(v, "Back to the menu", func(): menu_pressed.emit())

## "", "menu", "devices", "kits", "pause", "finish", "hud", "loading"
func show_only(which: String) -> void:
	menu.visible = which == "menu"
	devices.visible = which == "devices"
	pause.visible = which == "pause"
	finish.visible = which == "finish"
	loading.visible = which == "loading"
	hud.visible = which in ["hud", "pause"]
	kits_box.visible = which == "kits"
