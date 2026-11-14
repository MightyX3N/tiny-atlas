class_name Cyclist
extends Node3D
## A road cyclist in voxels: a realistic body (Quaternius' Universal Base Character, CC0) wearing a cycling kit
## painted onto its voxels, on a voxel road bike. Same interface as Runner: animate(dt, cadence, speed).
## Faces +Z. The kit and the bike paint come from Kits (unlockable).

const VS_BODY := 0.022     # voxel size of the rider (m)
const VS_BIKE := 0.01      # voxel size of the bike (m): fine enough that thin tubes stay solid
const BODY := "res://assets/cyclist/Superhero_Male_FullBody.gltf"
const SKIN_TEX := "res://assets/cyclist/T_Superhero_Male_Ligh.png"

var mode := "bike"
var crank := 0.0
var roll := 0.0
var t := 0.0
var lean_extra := 0.0
var pose_cadence := 0.0
var lean_pelvis := 26.0
var lean_spine := 20.0
var lean_neck := 38.0

var bike: Node3D
var front_wheel: Node3D
var rear_wheel: Node3D
var crank_node: Node3D
var pedals: Array = []
var pts := {}
var body: Node3D
var sk: Skeleton3D
var B := {}
var pieces: Array = []
var poser: Poser
var mat: StandardMaterial3D

class Poser extends SkeletonModifier3D:
	var c
	func _process_modification() -> void:
		c._pose(c.pose_cadence)

func _init(kit: Dictionary = {}, paint: Dictionary = {}) -> void:
	mat = Voxelize.material()
	if kit.is_empty(): kit = Kits.KITS[0]
	if paint.is_empty(): paint = Kits.PAINTS[0]
	_build_bike(paint)
	_build_body(kit)

func set_mode(m: String) -> void:
	mode = m   # the voxel cyclist always rides; walking pads use the Runner

# ---------- bike ----------
func _part(grid: Dictionary, vs: float, parent: Node3D, at := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = Voxelize.build(grid, vs, mat)
	mi.position = at
	parent.add_child(mi)
	return mi

func _build_bike(paint: Dictionary) -> void:
	if bike: bike.queue_free()
	var rb := RoadBike.new(); rb.vs = VS_BIKE
	pts = rb.points()
	bike = Node3D.new(); add_child(bike)
	_part(rb.frame(paint), VS_BIKE, bike)
	var wg := rb.wheel(paint)
	front_wheel = Node3D.new(); front_wheel.position = pts.front_axle; bike.add_child(front_wheel); _part(wg, RoadBike.VS_WHEEL, front_wheel)
	rear_wheel = Node3D.new(); rear_wheel.position = pts.rear_axle; bike.add_child(rear_wheel); _part(wg, RoadBike.VS_WHEEL, rear_wheel)
	crank_node = Node3D.new(); crank_node.position = pts.bb; bike.add_child(crank_node); _part(rb.cranks(), VS_BIKE, crank_node)
	pedals = []
	var pg := rb.pedal()
	for i in 2:
		var p := Node3D.new(); bike.add_child(p); _part(pg, VS_BIKE, p)
		pedals.append(p)
	_build_lights()

# ---------- bike lights: a white front light on the bar and a red one under the saddle ----------
var front_lamp: MeshInstance3D
var rear_lamp: MeshInstance3D
var front_beam: SpotLight3D
var rear_glow: OmniLight3D
var lights_on := false

func _lamp_mat(c: Color, on: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c * (1.0 if on else 0.25)
	if on:
		m.emission_enabled = true; m.emission = c; m.emission_energy_multiplier = 4.0
	return m

func _build_lights() -> void:
	# front: a small lamp body in the middle of the handlebar, its beam forward and a little down
	var bar: Vector3 = pts.bar
	front_lamp = MeshInstance3D.new()
	var fb := BoxMesh.new(); fb.size = Vector3(0.045, 0.035, 0.06)
	front_lamp.mesh = fb
	front_lamp.position = bar + Vector3(0, -0.035, 0.03)
	bike.add_child(front_lamp)
	var lens := MeshInstance3D.new()
	var lb := BoxMesh.new(); lb.size = Vector3(0.035, 0.025, 0.005)
	lens.mesh = lb; lens.position = Vector3(0, 0, 0.032); lens.name = "lens"
	front_lamp.add_child(lens)
	front_beam = SpotLight3D.new()
	front_beam.position = front_lamp.position + Vector3(0, 0, 0.04)
	# a SpotLight shines along its -Z: turn it to face forward (+Z), tilted 7 degrees down
	front_beam.rotation_degrees = Vector3(-7, 180, 0)
	front_beam.spot_range = 28.0
	front_beam.spot_angle = 22.0
	front_beam.spot_angle_attenuation = 1.6
	front_beam.light_energy = 6.0
	front_beam.light_color = Color(1.0, 0.97, 0.9)
	front_beam.shadow_enabled = true
	bike.add_child(front_beam)
	# rear: a red light on the seatpost, under the saddle, glowing a little on the ground behind
	var sad: Vector3 = pts.saddle
	rear_lamp = MeshInstance3D.new()
	var rbx := BoxMesh.new(); rbx.size = Vector3(0.03, 0.045, 0.02)
	rear_lamp.mesh = rbx
	rear_lamp.position = sad + Vector3(0, -0.1, -0.06)
	bike.add_child(rear_lamp)
	rear_glow = OmniLight3D.new()
	rear_glow.position = rear_lamp.position + Vector3(0, 0, -0.03)
	rear_glow.omni_range = 1.6
	rear_glow.light_energy = 0.35
	rear_glow.position = rear_lamp.position + Vector3(0, -0.05, -0.12)
	rear_glow.light_color = Color(1.0, 0.1, 0.06)
	bike.add_child(rear_glow)
	set_lights(lights_on)

## bike lights on or off (on in the dark: at night, in a tunnel)
func set_lights(on: bool) -> void:
	lights_on = on
	if front_lamp == null: return
	front_lamp.material_override = _lamp_mat(Color(0.08, 0.08, 0.09), false)
	(front_lamp.get_node("lens") as MeshInstance3D).material_override = _lamp_mat(Color(1.0, 0.97, 0.9), on)
	rear_lamp.material_override = _lamp_mat(Color(1.0, 0.1, 0.06), on)
	front_beam.visible = on
	rear_glow.visible = on

func repaint(paint: Dictionary) -> void:
	_build_bike(paint)

## pedal spindle positions (bike space) for the current crank angle: [left, right]
func _pedal_pos() -> Array:
	var r := Basis(Vector3.RIGHT, crank)
	var right: Vector3 = pts.bb + r * Vector3(-0.11, -RoadBike.CRANK, 0)
	var left: Vector3 = pts.bb + r * Vector3(0.11, RoadBike.CRANK, 0)
	return [left, right]

# ---------- body with the kit painted on ----------
func _build_body(kit: Dictionary) -> void:
	for p in pieces: p.queue_free()
	pieces = []
	if body: body.queue_free()
	body = (load(BODY) as PackedScene).instantiate()
	add_child(body)
	sk = body.find_children("*", "Skeleton3D", true, false)[0]
	for n in ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "Head", "clavicle_l", "clavicle_r",
		"thigh_l", "calf_l", "foot_l", "ball_l", "thigh_r", "calf_r", "foot_r", "ball_r",
		"upperarm_l", "lowerarm_l", "hand_l", "upperarm_r", "lowerarm_r", "hand_r"]:
		B[n] = sk.find_bone(n)
	# sit on the saddle: the pelvis bone a little above and in front of the saddle top
	var pel := sk.get_bone_global_rest(B.pelvis).origin
	body.position = (pts.saddle as Vector3) + Vector3(0, 0.1, 0.02) - pel
	var skin_img := Voxelize._image(load(SKIN_TEX))
	var mi: MeshInstance3D = null
	for m in body.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).visible = false
		if m.name == "SuperHero_Male": mi = m
	_voxel_body(mi, kit, skin_img)
	if poser == null or not is_instance_valid(poser):
		poser = Poser.new(); poser.c = self
	if poser.get_parent(): poser.get_parent().remove_child(poser)
	sk.add_child(poser)

func rekit(kit: Dictionary) -> void:
	_build_body(kit)

## bone lengths (to the first child), to know how far along a bone a point is
func _bone_len(b: int) -> float:
	var kids := sk.get_bone_children(b)
	if kids.is_empty(): return 0.1
	return sk.get_bone_rest(kids[0]).origin.length()

func _voxel_body(mi: MeshInstance3D, kit: Dictionary, skin_img: Image) -> void:
	var skin := mi.skin
	var bind_bone := {}
	var bone_name := {}
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0: b = sk.find_bone(skin.get_bind_name(i))
		bind_bone[i] = b
		bone_name[i] = sk.get_bone_name(b)
	var lens := {}
	for i in bind_bone: lens[i] = _bone_len(bind_bone[i])
	# the base character is a muscular "superhero": slim the arms and the upper body to a rider's build
	var slim := { "spine_02": 0.9, "spine_03": 0.86, "clavicle_l": 0.85, "clavicle_r": 0.85, "upperarm_l": 0.78,
		"upperarm_r": 0.78, "lowerarm_l": 0.85, "lowerarm_r": 0.85, "neck_01": 0.9, "thigh_l": 0.94, "thigh_r": 0.94 }
	# fists: the model's hands are open and flat. Each finger bone is curled towards the palm (the rest pose has the
	# palms down), and the finger's voxels are made from that curled finger, in the hand's space, so the glove closes
	# round the bar
	var curl := _finger_curls()
	var tri := { "fbind": null }      # the finger bone of the triangle being sampled (set by pick, read by to_bone)
	var to_bone := func(p: Vector3, bind) -> Vector3:
		if tri.fbind != null:
			var fb: int = bind_bone[tri.fbind]
			if curl.has(fb): return (curl[fb] as Transform3D) * (skin.get_bind_pose(tri.fbind) * p)
		var q: Vector3 = skin.get_bind_pose(bind) * p
		var f: float = slim.get(bone_name[bind], 1.0)
		return Vector3(q.x * f, q.y, q.z * f)
	var pick := func(arr: Array, i0: int, i1: int, i2: int):
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var score := {}
		for vi in [i0, i1, i2]:
			for k in per:
				var w: float = weights[vi * per + k]
				if w > 0.0: score[bones[vi * per + k]] = score.get(bones[vi * per + k], 0.0) + w
		var best = null; var bw := -1.0
		for k in score:
			if score[k] > bw: bw = score[k]; best = k
		# fingers belong to the hand (one rigid glove, made from the curled fingers)
		var bn := str(bone_name[best]) if best != null else ""
		tri.fbind = null
		if bn.begins_with("index") or bn.begins_with("middle") or bn.begins_with("ring") or bn.begins_with("pinky") or bn.begins_with("thumb"):
			var hb = _bind_of(bind_bone, sk.find_bone("hand_l" if bn.ends_with("_l") else "hand_r"))
			if hb != null:
				tri.fbind = best
				best = hb
		return best
	var paint := func(bind, pos: Vector3, mpos: Vector3, tex: Color):
		return _kit_colour(kit, str(bone_name[bind]), pos.y / maxf(lens[bind], 0.01), mpos, tex)
	var hips := sk.find_bone("pelvis")
	# built before the cyclist is in the scene, so only the bones' own scale counts (bone units to metres)
	var sc := sk.get_bone_global_rest(hips).basis.get_scale().x
	var vs := VS_BODY / maxf(sc, 1e-6)
	var g := Voxelize.sample(mi.mesh, to_bone, vs, skin_img, pick, Color.WHITE, paint)
	# helmet and glasses, made in the character's own (mesh) space and moved into the head bone's space
	var head_bind = _bind_of(bind_bone, B.Head)
	if head_bind != null and g.has(head_bind):
		_helmet(g[head_bind], skin.get_bind_pose(head_bind), vs, kit)
	for bind in g:
		var att := BoneAttachment3D.new()
		sk.add_child(att)
		att.bone_idx = bind_bone[bind]
		var piece := MeshInstance3D.new()
		piece.mesh = Voxelize.build(g[bind], vs, mat)
		att.add_child(piece)
		pieces.append(att)

## for each finger bone: the transform from its own space to its hand's space with the finger curled into a fist
## (knuckles 80 degrees, middle joints 95, tips 65; the thumb 25 each, folded over the fingers)
func _finger_curls() -> Dictionary:
	var out := {}
	var palm := Vector3.DOWN          # the rest pose has the palms facing down
	for side in ["_l", "_r"]:
		var hand := sk.find_bone("hand" + side)
		for f in ["index", "middle", "ring", "pinky", "thumb"]:
			var to_hand := Transform3D.IDENTITY
			for seg in [1, 2, 3]:
				var b := sk.find_bone("%s_0%d%s" % [f, seg, side])
				if b < 0: break
				var g := sk.get_bone_global_rest(b)
				var dir := g.basis.y.normalized()
				var axis_g := dir.cross(palm)
				if axis_g.length() < 0.01: axis_g = Vector3.BACK
				var axis_l := (g.basis.inverse() * axis_g.normalized()).normalized()
				var ang := ([25.0, 25.0, 25.0] if f == "thumb" else [80.0, 95.0, 65.0])[seg - 1] as float
				to_hand = to_hand * sk.get_bone_rest(b) * Transform3D(Basis(axis_l, deg_to_rad(ang)), Vector3.ZERO)
				out[b] = to_hand
			if hand < 0: continue
	return out

func _bind_of(bind_bone: Dictionary, bone: int):
	for k in bind_bone:
		if bind_bone[k] == bone: return k
	return null

## which part of the kit a point of the body wears
func _kit_colour(kit: Dictionary, bone: String, along: float, m: Vector3, tex: Color) -> Color:
	var jersey: Color = kit.jersey; var acc: Color = kit.accent
	var j := jersey
	match kit.pattern:
		"band": if m.y > 1.28 and m.y < 1.37: j = acc
		"hoops": if int(floor(m.y / 0.07)) % 2 == 0: j = acc
		"split": if m.x > 0.0: j = acc
		"stripe": if absf(m.x) < 0.035: j = acc
		"collar": if m.y > 1.47: j = acc
		"dots":
			var cell := Vector2(floor(m.x / 0.07 + (0.5 if int(floor(m.y / 0.07)) % 2 == 0 else 0.0)), floor(m.y / 0.07))
			var c := Vector2((cell.x + 0.5) * 0.07, (cell.y + 0.5) * 0.07)
			if Vector2(m.x, m.y).distance_to(c) < 0.022: j = acc
		"rainbow":
			var bands := [Color(0.1, 0.3, 0.75), Color(0.85, 0.1, 0.1), Color(0.06, 0.06, 0.07), Color(1.0, 0.8, 0.05), Color(0.1, 0.6, 0.25)]
			if m.y > 1.25 and m.y < 1.40: j = bands[clampi(int((m.y - 1.25) / 0.03), 0, 4)]
	match bone:
		"Head", "neck_01": return tex
		"spine_01", "spine_02", "spine_03", "clavicle_l", "clavicle_r": return j
		"pelvis": return j if m.y > 1.0 else kit.shorts
		"upperarm_l", "upperarm_r":
			if along < 0.55:
				return acc if kit.pattern == "sleeves" else (jersey if kit.pattern != "split" else j)
			return tex
		"lowerarm_l", "lowerarm_r": return tex
		"hand_l", "hand_r": return kit.gloves
		"thigh_l", "thigh_r": return kit.shorts if along < 0.8 else tex
		"calf_l", "calf_r": return tex if along < 0.62 else kit.socks
		"foot_l", "foot_r", "ball_l", "ball_r": return kit.shoes if m.y > 0.02 else Color(0.08, 0.08, 0.09)
	if bone.ends_with("_l") or bone.ends_with("_r"): return kit.gloves
	return j

## helmet shell with vents and wrap-around glasses, in mesh space -> head bone space
func _helmet(grid: Dictionary, to_head: Transform3D, vs: float, kit: Dictionary) -> void:
	var hc: Color = kit.helmet
	var vent := Color(0.08, 0.08, 0.09)
	var centre := Vector3(0, 1.725, -0.012)
	var rad := Vector3(0.112, 0.118, 0.142)
	var step := vs * 0.5
	var x := -0.15
	while x <= 0.15:
		var y := 1.6
		while y <= 1.87:
			var z := -0.18
			while z <= 0.16:
				var p := Vector3(x, y, z)
				var e := ((p - centre) / rad).length()
				var keep := e > 0.98 and e < 1.0 + 0.026 / rad.x
				# open at the face, lower at the back
				if keep and (y < 1.715 + clampf(z, 0.0, 1.0) * 0.6 or (z < -0.05 and y < 1.66)):
					keep = false
				if keep:
					var col := hc
					# vents: slots running front to back on the top
					if y > 1.76 and absf(fmod(absf(x) + 0.012, 0.045)) < 0.016 and z > -0.11 and z < 0.09: col = vent
					var q := to_head * p
					grid[Vector3i(floori(q.x / vs), floori(q.y / vs), floori(q.z / vs))] = [col.r, col.g, col.b, 1]
				z += step
			y += step
		x += step
	# glasses: a curved lens across the eyes, arms back to the ears
	var gc: Color = kit.glasses
	x = -0.075
	while x <= 0.075:
		var yy := 1.685
		while yy <= 1.725:
			var zz := 0.112 - x * x * 3.0
			var q := to_head * Vector3(x, yy, zz)
			grid[Vector3i(floori(q.x / vs), floori(q.y / vs), floori(q.z / vs))] = [gc.r, gc.g, gc.b, 1]
			yy += step
		x += step
	for side: float in [-1.0, 1.0]:
		var zz := 0.09
		while zz >= -0.02:
			var q := to_head * Vector3(side * 0.083, 1.712, zz)
			grid[Vector3i(floori(q.x / vs), floori(q.y / vs), floori(q.z / vs))] = [0.08, 0.08, 0.09, 1]
			zz -= step

# ---------- riding ----------
func animate(dt: float, cadence: float, speed: float) -> void:
	t += dt
	crank += cadence / 60.0 * TAU * dt
	roll += speed * dt / RoadBike.R_WHEEL
	crank_node.rotation = Vector3(crank, 0, 0)
	front_wheel.rotation = Vector3(roll, 0, 0)
	rear_wheel.rotation = Vector3(roll, 0, 0)
	var pp := _pedal_pos()
	for i in 2: (pedals[i] as Node3D).position = pp[i]
	lean_extra = lerpf(lean_extra, clampf((cadence - 90.0) / 20.0, 0.0, 1.0) * 6.0, dt * 3.0)
	pose_cadence = cadence

func _axis(v: Vector3) -> Vector3: return (sk.global_transform.basis.inverse() * v).normalized()

func _rot_global(bone: int, q: Quaternion) -> void:
	var g := sk.get_bone_global_pose(bone)
	var nb := Basis(q) * g.basis.orthonormalized()
	var p := sk.get_bone_parent(bone)
	var pg := sk.get_bone_global_pose(p) if p >= 0 else Transform3D()
	sk.set_bone_pose_rotation(bone, (pg.basis.orthonormalized().inverse() * nb).get_rotation_quaternion())

func _ik(u: int, l: int, e: int, target_w: Vector3, pole_w: Vector3) -> void:
	var inv := sk.global_transform.affine_inverse()
	var tg := inv * target_w; var pole := inv * pole_w
	var pu := sk.get_bone_global_pose(u).origin
	var pl := sk.get_bone_global_pose(l).origin
	var pe := sk.get_bone_global_pose(e).origin
	var a := pu.distance_to(pl); var b := pl.distance_to(pe)
	var c := clampf(pu.distance_to(tg), absf(a - b) + 1e-6, (a + b) * 0.999)
	var dir := (tg - pu).normalized()
	var x := (a * a - b * b + c * c) / (2.0 * c)
	var h := sqrt(maxf(a * a - x * x, 0.0))
	var pv := pole - pu
	var perp := (pv - dir * pv.dot(dir)).normalized()
	var mid := pu + dir * x + perp * h
	_rot_global(u, Quaternion((pl - pu).normalized(), (mid - pu).normalized()))
	pl = sk.get_bone_global_pose(l).origin; pe = sk.get_bone_global_pose(e).origin
	_rot_global(l, Quaternion((pe - pl).normalized(), (pu + dir * c - pl).normalized()))

func _pose(cadence: float) -> void:
	sk.reset_bone_poses()
	var gb := global_transform.basis.orthonormalized()
	var right_w := -gb.x    # the body's +x is its left
	var fwd_w := gb.z; var up_w := gb.y
	var ax := _axis(-right_w)   # rotating about the left axis by +angle tips the body forward
	# road position: hips rolled forward, a long flat back, head up looking down the road
	_rot_global(B.pelvis, Quaternion(ax, deg_to_rad(lean_pelvis)))
	_rot_global(B.spine_01, Quaternion(ax, deg_to_rad(lean_spine + lean_extra * 0.5)))
	_rot_global(B.spine_02, Quaternion(ax, deg_to_rad(lean_spine + lean_extra * 0.5)))
	_rot_global(B.spine_03, Quaternion(ax, deg_to_rad(lean_spine * 0.5)))
	_rot_global(B.neck_01, Quaternion(ax, deg_to_rad(-lean_neck)))
	_rot_global(B.Head, Quaternion(ax, deg_to_rad(-lean_neck * 0.7)))
	if cadence > 1.0:
		_rot_global(B.pelvis, Quaternion(_axis(fwd_w), sin(crank) * deg_to_rad(2.5)))
	# legs: ankles over the pedals (ball of the foot on the pedal), knees forward
	var pp := _pedal_pos()
	var bt := bike.global_transform
	for side in 2:
		var pedal_w: Vector3 = bt * (pp[side] as Vector3)
		var ankle_w := pedal_w + up_w * 0.075 - fwd_w * 0.11
		var lr := 1.0 if side == 0 else -1.0   # left is +x
		var thigh: int = B.thigh_l if side == 0 else B.thigh_r
		var calf: int = B.calf_l if side == 0 else B.calf_r
		var foot: int = B.foot_l if side == 0 else B.foot_r
		var ball: int = B.ball_l if side == 0 else B.ball_r
		_ik(thigh, calf, foot, ankle_w, ankle_w + fwd_w * 1.2 + up_w * 0.9 - right_w * lr * 0.05)
		var fg := sk.get_bone_global_pose(foot)
		var bp := sk.get_bone_global_pose(ball).origin
		var toe_dir := _axis(fwd_w * 0.97 - up_w * (0.1 + 0.15 * sin(crank + (0.0 if side == 0 else PI))))
		_rot_global(foot, Quaternion((bp - fg.origin).normalized(), toe_dir))
	# arms to the brake hoods, elbows slightly out and bent
	for side in 2:
		var hood: Vector3 = bt * ((pts.hood_l if side == 0 else pts.hood_r) as Vector3)
		var wrist := hood + up_w * 0.035 - fwd_w * 0.05
		var lr := 1.0 if side == 0 else -1.0
		var ua: int = B.upperarm_l if side == 0 else B.upperarm_r
		var la: int = B.lowerarm_l if side == 0 else B.lowerarm_r
		var hd: int = B.hand_l if side == 0 else B.hand_r
		_ik(ua, la, hd, wrist, wrist - fwd_w * 0.2 - right_w * lr * 0.35 - up_w * 0.3)
		# hand: palm down on the hood, fingers forward
		var hg := sk.get_bone_global_pose(hd)
		var kids := sk.get_bone_children(hd)
		if not kids.is_empty():
			var mid := sk.get_bone_global_pose(kids[0]).origin
			_rot_global(hd, Quaternion((mid - hg.origin).normalized(), _axis(fwd_w * 0.9 - up_w * 0.2)))
