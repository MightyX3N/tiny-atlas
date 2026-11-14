extends Node3D
## VoxTrainer: ride a real route on a bike trainer (or walk it on a walking pad) through a world built from
## OpenStreetMap in 10 cm voxels by VoxBox. The world comes from VoxBox's builder as tile files + world.json.
##
## Command line (after --):
##   --world=DIR   the built world (default: "world" next to the game, or res://world)
##   --tour=DIR    takes pictures along the route and quits
##   --autotest    a bot rides the whole route at 40 km/h in real time, checks nothing visible loads late, quits

const GEAR := 0.33           # km/h per rpm on the flat with keyboard / cadence-only sensors
var bot_kmh := 40.0          # the test bot rides fast, in real time, so loading has to keep up (--botkmh=N)

var world_dir := ""
var world: VoxboxWorld
var length := 0.0           # metres along the ride line
var rider: Node3D          # the Cyclist on a bike, the Runner for walking pads
var cyclist: Cyclist
var runner: Runner
var kits: Kits
var counted := 0.0          # metres of this ride already added to the progress
var cam: Camera3D
var ui: GameUI
var state := "menu"
var d := 0.0
var speed := 0.0
var kb_cadence := 0.0
var ride_time := 0.0
var orbit := 0.0
var dev_t := 0.0
var grade_t := 0.0
var auto := false
var tour_dir := ""
var bot_value := 85.0
var cam_pos := Vector3.ZERO
var cam_mode := 0
var kb_brake := false
var help_l: Label
var tour_frames := 240
var devtest := false
var keytest := false
var kittest := false
var loadtest := false
var tour_spots := ""

func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a in args:
		if a == "--autotest": auto = true
		elif a.begins_with("--world="): world_dir = a.substr(8)
		elif a.begins_with("--tour="): tour_dir = a.substr(7)
		elif a.begins_with("--frames="): tour_frames = int(a.substr(9))
		elif a == "--devtest": devtest = true
		elif a == "--keytest": keytest = true
		elif a == "--kittest": kittest = true
		elif a.begins_with("--cam="): cam_mode = int(a.substr(6))
		elif a.begins_with("--spots="): tour_spots = a.substr(8)
		elif a.begins_with("--botkmh="): bot_kmh = float(a.substr(9))
		elif a == "--loadtest": loadtest = true
	world = VoxboxWorld.new(); add_child(world)
	if not world.open(world_dir if world_dir != "" else VoxboxWorld.default_dir()):
		get_tree().quit(1); return
	length = world.length
	kits = Kits.new()
	if auto or devtest or keytest: kits.kit_id = "club"; kits.paint_id = "carbon"
	cyclist = Cyclist.new(kits.kit(), kits.paint()); add_child(cyclist)
	rider = cyclist
	cam = Camera3D.new(); cam.fov = 70; cam.near = 0.05; cam.far = 3000; add_child(cam); cam.make_current()
	ui = GameUI.new(); add_child(ui)
	ui.route_l.text = "%s, %.1f km" % [str(world.info.get("name", "Your route")), length / 1000.0]
	help_l = Label.new()
	help_l.text = "W / ↑  pedal (hold)     Shift  sprint     S / ↓  brake\nA / ←  back 100 m     D / →  forward 100 m\nC  camera     H  hide keys     Esc  pause"
	help_l.add_theme_font_size_override("font_size", 18)
	help_l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	help_l.add_theme_constant_override("outline_size", 6)
	help_l.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	help_l.position += Vector2(-20, 16)
	help_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	help_l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ui.add_child(help_l)
	ui.start_pressed.connect(_start)
	ui.devices_pressed.connect(func(): state = "devices"; ui.show_only("devices"); Bt.scan(true); ui.hills_cb.set_pressed_no_signal(Bt.hills_allowed()))
	ui.back_pressed.connect(func(): Bt.scan(false); _to_menu())
	ui.quit_pressed.connect(func(): get_tree().quit())
	ui.resume_pressed.connect(func(): state = "ride"; ui.show_only("hud"))
	ui.menu_pressed.connect(func(): d = 0.0; _to_menu())
	ui.again_pressed.connect(func(): d = 0.0; _start())
	ui.connect_pressed.connect(func(addr, nm): Bt.connect_device(addr, nm))
	ui.forget_pressed.connect(func(addr): Bt.forget(addr))
	ui.hills_toggled.connect(func(on): Bt.allow_hills(on))
	ui.kit_pressed.connect(func(): state = "kits"; ui.fill_kits(kits); ui.show_only("kits"))
	ui.kit_chosen.connect(_choose_kit)
	_place_rider(0.0)
	cam_pos = rider.global_position + Vector3(0, 3, 6)
	# tests run like the real game does (vsync, 60 frames a second), not flat out, so the loading threads get the CPU
	# they would have
	if auto or devtest or keytest or kittest or loadtest: Engine.max_fps = 60
	var t0 := Time.get_ticks_msec()
	await _wait_world(0.0)
	print("WORLD loaded in %.1f s: %d regions, %d triangles, %.0f MB; %d builds took %.1f s of thread time" % [(Time.get_ticks_msec() - t0) / 1000.0,
		world.loader.stats.regions, world.loader.stats.triangles, Performance.get_monitor(Performance.MEMORY_STATIC) / 1e6,
		world.loader.stats.jobs, world.loader.stats.job_ms / 1000.0])
	world.loader.reset_stats()
	if auto:
		_start()
	elif devtest:
		_devtest()
	elif keytest:
		_keytest()
	elif kittest:
		_kittest()
	elif loadtest:
		_loadtest()
	elif tour_dir != "":
		_tour()
	else:
		_to_menu()

# ---------- the rider's line ----------

func pos(at: float) -> Vector3: return world.pos(at)
func dir(at: float) -> Vector3: return world.dir_at(at)

## walking pads get the runner (the voxel cyclist only rides)
func _use_rider(on_foot: bool) -> void:
	var want: Node3D = cyclist
	if on_foot:
		if runner == null:
			runner = Runner.new(); add_child(runner)
		want = runner
	if want == rider: return
	rider.visible = false
	rider = want
	rider.visible = true

func _choose_kit(kind: String, id: String) -> void:
	if kind == "kit":
		kits.kit_id = id; cyclist.rekit(kits.kit())
	else:
		kits.paint_id = id; cyclist.repaint(kits.paint())
	kits.save()
	ui.fill_kits(kits)

## progress counts every 100 m, so unlocks pop up during the ride
func _count_progress(finished: bool) -> Array:
	if auto or devtest or keytest: return []
	var newly := []
	while d - counted >= 100.0:
		counted += 100.0
		newly += kits.add(0.1, false)
	if finished:
		newly += kits.add((d - counted) / 1000.0, true)
		counted = d
	for n in newly: ui.show_message("Unlocked: " + n + "!", Color(1.0, 0.85, 0.3), 4.0)
	return newly

var wheel_h := Vector2(NAN, NAN)   # ground height under the rear and front wheel, eased

func _place_rider(at: float) -> void:
	var p := pos(at)
	var f := dir(at)
	var right := Vector3.UP.cross(f).normalized()
	world.at = at
	if rider == cyclist:
		# the wheels stand on the voxels under them (kerbs, ramps, crossings), not on a smoothed line
		var rear := p + f * RoadBike.REAR_Z
		var front := p + f * RoadBike.FRONT_Z
		var hr := world.ground_y(rear.x, rear.z, p.y)
		var hf := world.ground_y(front.x, front.z, p.y)
		var k := 1.0 if is_nan(wheel_h.x) or absf(wheel_h.x - hr) > 0.6 else clampf(get_process_delta_time() * 18.0, 0.0, 1.0)
		wheel_h = Vector2(lerpf(wheel_h.x if not is_nan(wheel_h.x) else hr, hr, k), lerpf(wheel_h.y if not is_nan(wheel_h.y) else hf, hf, k))
		var wb := RoadBike.FRONT_Z - RoadBike.REAR_Z
		p.y = wheel_h.x + (wheel_h.y - wheel_h.x) * (-RoadBike.REAR_Z / wb)
		var pitch := atan2(wheel_h.y - wheel_h.x, wb)
		var fp := (f * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
		rider.global_transform = Transform3D(Basis(right, fp.cross(right).normalized(), fp).orthonormalized(), p)
	else:
		p.y = world.ground_y(p.x, p.z, p.y)
		rider.global_transform = Transform3D(Basis(right, Vector3.UP, f), p)

func _camera(dt: float) -> void:
	var p := rider.global_position
	var f := dir(d + 3.0)
	var right := f.cross(Vector3.UP).normalized()
	var want: Vector3
	var look := p + f * 6.0 + Vector3.UP * 1.1
	match cam_mode:
		0: want = p - f * 4.6 + Vector3.UP * 2.0
		1: want = p - f * 2.4 + Vector3.UP * 1.6
		2: want = p + right * 4.0 + Vector3.UP * 1.4; look = p + Vector3.UP * 1.0
		3: want = p - f * 12.0 + Vector3.UP * 9.0; look = p + f * 10.0
	cam_pos = cam_pos.lerp(want, 1.0 - exp(-dt * 4.0))
	# don't look from inside a wall (narrow passages, tight streets): come in towards the rider until it's clear
	var head := p + Vector3.UP * 1.5
	var to := cam_pos - head
	var n := int(to.length() / 0.25)
	var clear := cam_pos
	for i in range(1, n + 1):
		var q := head + to * (float(i) / n)
		if world.solid_at(q) or world.solid_at(q + Vector3.UP * 0.3):
			clear = head + to * (maxf(float(i) - 1.5, 0.0) / n)
			break
	cam.global_position = clear
	cam.look_at(look, Vector3.UP)

# ---------- states ----------

func _to_menu() -> void:
	state = "menu"
	ui.show_only("menu")
	Bt.set_grade(null)
	var s := ""
	if Bt.fake: s = "Pretend devices (--fake). "
	if Bt.connected(): s += "Devices connected. "
	elif Bt.bridge == null: s += "Bluetooth isn't available (%s). " % Bt.error_text
	else: s += "No devices connected: use ↑ / ↓ for cadence. "
	ui.menu_status.text = s

func _start() -> void:
	state = "ride"
	cam.h_offset = 0.0
	ui.show_only("hud")
	d = 0.0; speed = 0.0; ride_time = 0.0; counted = 0.0
	kb_cadence = 0.0
	Bt.scan(false)
	Bt.set_grade(0.0)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		var k: int = e.keycode
		if k == KEY_ESCAPE:
			if state == "ride": state = "pause"; ui.show_only("pause")
			elif state == "pause": state = "ride"; ui.show_only("hud")
			elif state == "devices": Bt.scan(false); _to_menu()
			elif state == "kits": _to_menu()
		elif k == KEY_RIGHT or k == KEY_D: _jump(100.0)
		elif k == KEY_LEFT or k == KEY_A: _jump(-100.0)
		elif k == KEY_C: cam_mode = (cam_mode + 1) % 4; ui.show_message(["Camera: behind", "Camera: close", "Camera: side", "Camera: high"][cam_mode])
		elif k == KEY_H or k == KEY_F1: help_l.visible = not help_l.visible
		elif Bt.fake and k >= KEY_0 and k <= KEY_3: Bt.fake_effort(k - KEY_0)

## keyboard riding (when no devices): hold W / ↑ to pedal, Shift to sprint, S / ↓ to brake
func _keyboard(dt: float) -> void:
	var pedal := Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)
	var brake := Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)
	var want := 0.0
	if pedal: want = 110.0 if Input.is_key_pressed(KEY_SHIFT) else 85.0
	kb_cadence = move_toward(kb_cadence, want, dt * (60.0 if pedal else 40.0))
	kb_brake = brake

func _jump(metres: float) -> void:
	if state != "ride": return
	d = clampf(d + metres, 0.0, length - 1.0)
	_place_rider(d)
	cam_pos = rider.global_position - dir(d) * 4.6 + Vector3.UP * 2.0
	if not world.is_ready(d):
		# jumped somewhere not loaded yet (backwards): wait for it instead of showing it half built
		await _wait_world(d)
		state = "ride"; ui.show_only("hud")
	ui.show_message("%.0f m" % d)

## shows the loading screen until the route from `m` on is loaded
func _wait_world(m: float) -> void:
	state = "loading"
	ui.show_only("loading")
	# nothing 3D to draw behind the loading screen: the frames stay cheap and the loading threads get the CPU
	get_viewport().disable_3d = true
	while not world.is_ready(m):
		ui.loading.text = "Loading the route...  %d %%" % int(world.progress(m) * 100.0)
		await get_tree().process_frame
	get_viewport().disable_3d = false

func _kind() -> String:
	return str(Bt.value("kind", "")) if Bt.connected() else ""

func _on_foot() -> bool:
	return _kind() in ["sperax", "ftms_treadmill", "rsc"]

## [speed km/h, cadence, power, hr]
func _inputs() -> Array:
	if auto: return [bot_kmh, bot_value, -1.0, -1.0]
	if not Bt.connected():
		return [kb_cadence * GEAR, kb_cadence, -1.0, -1.0]
	var spd: float = Bt.value("speed_kmh"); var cad: float = Bt.value("cadence")
	var pw: float = Bt.value("power"); var hr: float = Bt.value("hr")
	if spd < 0.0: spd = maxf(cad, 0.0) * GEAR if not _on_foot() else 0.0
	if not Bt.value("moving", false): spd = 0.0
	return [spd, cad, pw, hr]

func _process(dt: float) -> void:
	match state:
		"menu", "devices", "kits":
			orbit += dt * 0.05
			var p := pos(10.0)
			if state == "kits":
				# close up, the rider to the right of the list
				var a := orbit * 3.0
				cam.global_position = p + Vector3(cos(a) * 3.6, 1.5, sin(a) * 3.6)
				cam.look_at(p + Vector3.UP * 0.9, Vector3.UP)
				cam.h_offset = -0.9
			else:
				cam.h_offset = 0.0
				cam.global_position = p + Vector3(cos(orbit) * 14.0, 5.0, sin(orbit) * 14.0)
				cam.look_at(p + Vector3.UP * 1.4, Vector3.UP)
			_place_rider(10.0)
			rider.animate(dt, 0.0, 0.0)
			if state == "devices": _devices_screen(dt)
		"ride": _ride(dt)

func _devices_screen(dt: float) -> void:
	dev_t -= dt
	if dev_t > 0.0: return
	dev_t = 0.5
	var live := ""
	if Bt.connected():
		var v := _inputs()
		live = "Now: %.1f km/h   %d rpm   %s W   %s bpm" % [v[0], int(maxf(v[1], 0)), str(int(v[2])) if v[2] >= 0 else "--", str(int(v[3])) if v[3] > 0 else "--"]
	var note := ""
	if Bt.bridge == null or not Bt.available: note = "Bluetooth isn't available here: " + Bt.error_text
	ui.fill_devices(Bt.connections(), Bt.nearby(), live, note)

func _ride(dt: float) -> void:
	ride_time += dt
	var inp := _inputs()
	if not Bt.connected() and not auto: _keyboard(dt)
	var target: float = inp[0] / 3.6
	if _on_foot(): target = inp[0] * Bt.walk_factor(0.0) / 3.6
	speed = lerpf(speed, target, 1.0 - exp(-dt * (6.0 if kb_brake else 2.0)))
	if kb_brake: speed = move_toward(speed, 0.0, dt * 4.0)
	if auto:
		_bot_report()
		# hitches: frames that took more than twice a 60 fps frame
		if ride_time > 1.0:
			dt_max = maxf(dt_max, dt)
			if dt > 1.0 / 30.0: slow_frames += 1
	d = minf(d + speed * dt, length)
	_place_rider(d)
	_use_rider(_on_foot())
	rider.animate(dt, maxf(inp[1], 0.0) if not _on_foot() else 0.0, speed)
	_camera(dt)
	grade_t -= dt
	if grade_t <= 0.0: grade_t = 1.0; Bt.set_grade(0.0)
	ui.set_stats(speed * 3.6, inp[1], "spm" if _on_foot() else "rpm", inp[2], inp[3])
	ui.set_progress(d, length, 0.0)
	if not Bt.connected() and not auto:
		ui.dev_l.text = "Keyboard: hold W to pedal (%d rpm)  ·  H for keys" % int(kb_cadence)
	_count_progress(false)
	if d >= length - 0.01:
		if auto:
			var st: Dictionary = world.loader.stats
			var ok: bool = st.missing_max == 0 and st.coarse_max == 0
			print("TEST finished: %.0f m in %.0f s at %.0f km/h. Pop-in: %d regions seen but not shown, %d shown too coarse too close (most at once). Building used %.0f s of worker time = %.2f cores at this speed" % [
				length, ride_time, bot_kmh, st.missing_max, st.coarse_max, st.job_ms / 1000.0, st.job_ms / 1000.0 / ride_time])
			print("TEST frames: slowest %.0f ms, %d over 33 ms; the loader's main-thread work: slowest update %.1f ms (planning %.1f ms, putting meshes on screen %.1f ms), %d updates over 8 ms" % [
				dt_max * 1000.0, slow_frames, st.update_ms_max, st.plan_ms_max, st.apply_ms_max, st.slow_updates])
			print("TEST RESULT " + ("PASS" if ok else "FAIL"))
			get_tree().quit(0 if ok else 1)
			return
		state = "finish"
		Bt.set_grade(null)
		var newly := _count_progress(true)
		ui.finish_l.text = "Route done!\n%.2f km in %d:%02d" % [length / 1000.0, int(ride_time) / 60, int(ride_time) % 60]
		if not newly.is_empty(): ui.finish_l.text += "\nUnlocked: " + ", ".join(newly)
		ui.show_only("finish")

# ---------- self test: does the world load under the rider? ----------
var report_at := 0.0
var dt_max := 0.0
var slow_frames := 0

## every 200 m: what's loaded, and whether anything seen from here was missing
func _bot_report() -> void:
	if d < report_at: return
	report_at += 200.0
	var st: Dictionary = world.loader.stats
	print("TEST at %.0f m: %d regions, %d triangles %s, %.0f MB, missing %d (most %d), too coarse %d (most %d), %d jobs" % [d, st.regions,
		st.triangles, str(world.loader.triangles_by_level()), Performance.get_monitor(Performance.MEMORY_STATIC) / 1e6, st.missing, st.missing_max, st.coarse, st.coarse_max, st.jobs])

# ---------- load test: how much building riding a kilometre takes ----------
## Moves along the route 25 m at a time and lets the loader finish each time, adding up the building time.
## That gives the CPU time a kilometre needs, so the speed a computer can keep up with is known.
func _loadtest() -> void:
	state = "tour"
	var m := 0.0
	while m <= length:
		d = m; _place_rider(d)
		await get_tree().process_frame
		await get_tree().process_frame
		var waited := 0
		while not world.loader.is_idle():
			await get_tree().process_frame
			waited += 1
			if waited % 1800 == 0:
				var n := 0
				for key in world.loader.regions:
					var r = world.loader.regions[key]
					if r.lod != r.want and n < 5: print("LOADTEST waiting at %.0f m: %s lod %d want %d building %d" % [m, key, r.lod, r.want, r.building]); n += 1
				print("LOADTEST running ", world.loader._running, " tasks ", world.loader._tasks.size())
		m += 25.0
	var st: Dictionary = world.loader.stats
	var per_km: float = st.job_ms / 1000.0 / (length / 1000.0)
	print("LOADTEST %.0f m: %d builds, %.1f s of building per km. One thread keeps up to %.0f km/h; with %d threads (this computer) %.0f km/h" % [
		length, st.jobs, per_km, 3600.0 / per_km, world.loader._threads, 3600.0 / per_km * world.loader._threads])
	get_tree().quit()

# ---------- device test: connect OmniPlay's pretend bike, pedal, check the rider moves ----------
func _devtest() -> void:
	var wait := func(secs: float) -> void:
		var t := 0.0
		while t < secs:
			await get_tree().process_frame
			t += get_process_delta_time()
	state = "devices"; ui.show_only("devices"); Bt.scan(true)
	await wait.call(2.0)
	var found := ""
	for n in Bt.nearby():
		print("DEVTEST nearby: ", n.get("name"), " ", n.get("addr"))
		if str(n.get("name", "")).contains("EM 8000"): found = str(n.get("addr"))
	var remembered := false
	for c in Bt.connections():
		if str(c.get("name", "")).contains("EM 8000"): remembered = true
	if found == "" and not remembered: print("DEVTEST RESULT FAIL (no bike found)"); get_tree().quit(1); return
	if remembered: print("DEVTEST bike remembered from last time, reconnecting by itself")
	else: Bt.connect_device(found, "EM 8000")
	await wait.call(3.0)
	print("DEVTEST connected: ", Bt.connected(), " kind ", _kind(), " conns ", Bt.connections())
	Bt.fake_effort(2)
	_start()
	await wait.call(25.0)
	print("DEVTEST after 25 s: %.1f m, %.1f km/h, cadence %s, power %s" % [d, speed * 3.6, str(Bt.value("cadence")), str(Bt.value("power"))])
	var ok := Bt.connected() and d > 20.0
	print("DEVTEST RESULT " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

# ---------- keyboard test: hold W, sprint, jump, brake ----------
func _key(k: Key, down: bool) -> void:
	var e := InputEventKey.new(); e.keycode = k; e.physical_keycode = k; e.pressed = down
	Input.parse_input_event(e)

func _keytest() -> void:
	var wait := func(secs: float) -> void:
		var t := 0.0
		while t < secs:
			await get_tree().process_frame
			t += get_process_delta_time()
	_start()
	_key(KEY_W, true); await wait.call(8.0)
	var d1 := d; var v1 := speed * 3.6
	_key(KEY_SHIFT, true); await wait.call(5.0)
	var v2 := speed * 3.6
	_key(KEY_SHIFT, false); _key(KEY_W, false)
	_key(KEY_D, true); await wait.call(0.1); _key(KEY_D, false)
	# a jump can land somewhere still loading: that shows the loading screen until it's ready
	while state != "ride": await get_tree().process_frame
	var d2 := d
	_key(KEY_S, true); await wait.call(3.0); _key(KEY_S, false)
	var v3 := speed * 3.6
	print("KEYTEST hold W 8 s: %.0f m at %.1f km/h; sprint: %.1f km/h; D jumped to %.0f m; brake: %.1f km/h" % [d1, v1, v2, d2, v3])
	var ok := d1 > 20.0 and v2 > v1 + 3.0 and d2 > d1 + 100.0 and v3 < 1.0
	print("KEYTEST RESULT " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

# ---------- kit test: riding past 5 km unlocks a kit, the Kit & bike screen picks it ----------
func _kittest() -> void:
	var wait := func(secs: float) -> void:
		var tt := 0.0
		while tt < secs:
			await get_tree().process_frame
			tt += get_process_delta_time()
	kits.total_km = 4.95; kits.rides = 0; kits.kit_id = "club"; kits.paint_id = "carbon"
	var shots: String = tour_dir
	_start()
	kb_cadence = 0.0
	_key(KEY_W, true); await wait.call(20.0); _key(KEY_W, false)
	print("KITTEST rode %.0f m, total %.2f km, classic unlocked: %s" % [d, kits.total_km, kits.is_unlocked(Kits.find(Kits.KITS, "classic"))])
	state = "kits"; ui.fill_kits(kits); ui.show_only("kits")
	_choose_kit("kit", "classic")
	_choose_kit("paint", "carbon")
	await wait.call(1.0)
	if shots != "":
		for i in 30: await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(shots + "/kits.png")
	var saved := FileAccess.get_file_as_string("user://progress.json")
	var ok := kits.is_unlocked(Kits.find(Kits.KITS, "classic")) and saved.contains("classic")
	print("KITTEST saved: ", saved)
	print("KITTEST RESULT " + ("PASS" if ok else "FAIL"))
	kits.total_km = 0.0; kits.kit_id = "club"; kits.save()
	get_tree().quit(0 if ok else 1)

# ---------- pictures along the route ----------

func _tour() -> void:
	state = "tour"
	ui.show_only("hud")
	DirAccess.make_dir_recursive_absolute(tour_dir)
	var spots := [5.0, length * 0.15, length * 0.35, length * 0.55, length * 0.75, length * 0.95]
	if tour_spots != "":
		spots = []
		for v in tour_spots.split(","): spots.append(float(v))
	var k := 0
	for at in spots:
		d = at
		_place_rider(d)
		await _wait_world(d)
		state = "tour"; ui.show_only("hud")
		rider.animate(1.0 / 30.0, 80.0, 7.0)
		cam_pos = rider.global_position - dir(d) * 4.6 + Vector3.UP * 2.0
		# let the engine stream and mesh this spot, and the light settle
		for i in tour_frames:
			rider.animate(1.0 / 30.0, 80.0, 7.0)
			_camera(1.0 / 30.0)
			ui.set_stats(26.0, 80.0, "rpm", -1, -1)
			ui.set_progress(d, length, 0.0)
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/ride_%d.png" % [tour_dir, k]); k += 1
		print("tour ride_%d at %.0f m" % [k - 1, d])
	get_tree().quit()
