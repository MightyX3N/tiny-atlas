class_name RoadBike
extends RefCounted
## A road bike made of voxels by rules (size ~56 cm): frame, fork, drop bars, saddle, two 700c wheels, crankset
## and pedals. Bike space: x right, y up, z forward, ground at y = 0, bottom bracket at z = 0.
## Returns the parts as voxel grids plus the points the rider needs (saddle, hoods, crank centre).

const R_WHEEL := 0.335         # 700x25 tyre
const REAR_Z := -0.405
const FRONT_Z := 0.575
const BB := Vector3(0, 0.265, 0)
const CRANK := 0.172

var vs := 0.02
var saddle_height := 0.76      # bottom bracket to the top of the saddle

static func _seat_dir() -> Vector3: return Vector3(0, sin(deg_to_rad(73.5)), -cos(deg_to_rad(73.5)))

func points() -> Dictionary:
	var sd := _seat_dir()
	var head_top := BB + Vector3(0, 0.57, 0.385)
	var bar := head_top + Vector3(0, 0.03, 0.10)
	return {
		"saddle": BB + sd * saddle_height + Vector3(0, 0.0, 0.0),
		"head_top": head_top,
		"bar": bar,
		"hood_l": bar + Vector3(0.20, 0.035, 0.085),
		"hood_r": bar + Vector3(-0.20, 0.035, 0.085),
		"front_axle": Vector3(0, R_WHEEL, FRONT_Z),
		"rear_axle": Vector3(0, R_WHEEL, REAR_Z),
		"bb": BB,
	}

# ---------- voxel drawing ----------
func _key(p: Vector3) -> Vector3i: return Vector3i(floori(p.x / vs), floori(p.y / vs), floori(p.z / vs))

func tube(g: Dictionary, a: Vector3, b: Vector3, r: float, col: Color, r2 := -1.0) -> void:
	if r2 < 0.0: r2 = r
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z)) - Vector3.ONE * (maxf(r, r2) + vs)
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z)) + Vector3.ONE * (maxf(r, r2) + vs)
	var k0 := _key(lo); var k1 := _key(hi)
	var ab := b - a
	var L2 := maxf(ab.length_squared(), 1e-9)
	for x in range(k0.x, k1.x + 1):
		for y in range(k0.y, k1.y + 1):
			for z in range(k0.z, k1.z + 1):
				var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * vs
				var t := clampf((p - a).dot(ab) / L2, 0.0, 1.0)
				var rr := lerpf(r, r2, t)
				# at least one voxel thick, so thin tubes don't break up
				if p.distance_to(a + ab * t) <= maxf(rr, vs * 0.8): g[Vector3i(x, y, z)] = col

func path(g: Dictionary, pts: Array, r: float, col: Color) -> void:
	for i in pts.size() - 1: tube(g, pts[i], pts[i + 1], r, col)

func box(g: Dictionary, c: Vector3, half: Vector3, col: Color) -> void:
	var k0 := _key(c - half); var k1 := _key(c + half)
	for x in range(k0.x, k1.x + 1):
		for y in range(k0.y, k1.y + 1):
			for z in range(k0.z, k1.z + 1): g[Vector3i(x, y, z)] = col

static func _grid_to_mesh_data(g: Dictionary) -> Dictionary:
	var out := {}
	for k in g:
		var c: Color = g[k]
		out[k] = [c.r, c.g, c.b, 1]
	return out

# ---------- parts ----------
func frame(paint: Dictionary) -> Dictionary:
	var g := {}
	var fc: Color = paint.frame; var ac: Color = paint.accent
	var p := points()
	var sd := _seat_dir()
	var seat_top := BB + sd * 0.53
	var head_top: Vector3 = p.head_top
	var hd := Vector3(0, -sin(deg_to_rad(73.0)), cos(deg_to_rad(73.0)))
	var head_bot := head_top + hd * 0.16
	var fa: Vector3 = p.front_axle; var ra: Vector3 = p.rear_axle
	tube(g, BB, seat_top, 0.017, fc)                                  # seat tube
	tube(g, seat_top + Vector3(0, -0.01, 0), head_top + hd * 0.02, 0.016, fc)   # top tube
	tube(g, BB, head_bot, 0.022, fc, 0.02)                           # down tube
	tube(g, head_top, head_bot, 0.02, fc)                             # head tube
	for side: float in [-1.0, 1.0]:
		tube(g, BB + Vector3(side * 0.03, 0, -0.02), ra + Vector3(side * 0.065, 0, 0), 0.011, fc)      # chain stays
		tube(g, seat_top + Vector3(side * 0.02, -0.04, -0.01), ra + Vector3(side * 0.065, 0, 0), 0.009, fc)  # seat stays
		tube(g, head_bot + Vector3(side * 0.02, 0, 0), fa + Vector3(side * 0.055, 0, 0), 0.014, fc, 0.009)  # fork legs
	# accent stripe on the down tube
	var dt := head_bot - BB
	for t: float in [0.55, 0.62]:
		tube(g, BB + dt * t, BB + dt * (t + 0.04), 0.024, ac)
	# seat post + saddle
	var saddle: Vector3 = p.saddle
	tube(g, seat_top, saddle - sd * 0.04, 0.0135, Color(0.12, 0.12, 0.13))
	var sc: Color = paint.saddle
	for i in 14:
		var z := -0.17 + i * 0.02            # rear .. nose
		var w := lerpf(0.07, 0.016, clampf((z + 0.06) / 0.14, 0.0, 1.0)) if z > -0.06 else 0.07
		box(g, saddle + Vector3(0, -0.012, z + 0.03), Vector3(w, 0.012, 0.011), sc)
	# stem, drop bars (tops, hoods, drops) with bar tape
	var bar: Vector3 = p.bar
	tube(g, head_top, bar, 0.016, Color(0.1, 0.1, 0.11))
	tube(g, head_top, head_top + Vector3(0, 0.035, 0), 0.02, Color(0.1, 0.1, 0.11))   # spacers / top cap
	var tape: Color = paint.tape
	tube(g, bar + Vector3(-0.2, 0, 0), bar + Vector3(0.2, 0, 0), 0.013, Color(0.12, 0.12, 0.13))
	for side: float in [-1.0, 1.0]:
		var x := side * 0.2
		var drop := [bar + Vector3(x, 0, 0), bar + Vector3(x, 0.0, 0.06), bar + Vector3(x, -0.03, 0.095),
			bar + Vector3(x, -0.08, 0.1), bar + Vector3(x, -0.12, 0.075), bar + Vector3(x, -0.13, 0.03), bar + Vector3(x, -0.125, -0.02)]
		path(g, drop, 0.013, tape)
		# brake hood / lever
		var hood: Vector3 = p.hood_l if side > 0 else p.hood_r
		tube(g, bar + Vector3(x, 0.0, 0.07), hood + Vector3(0, 0.0, 0.02), 0.017, Color(0.08, 0.08, 0.09))
		tube(g, hood + Vector3(0, -0.01, 0.03), hood + Vector3(0, -0.11, 0.045), 0.008, Color(0.7, 0.7, 0.72))
	# chainring (right side) and a bottle on the down tube
	var cr := Color(0.25, 0.25, 0.27)
	for a in 36:
		var ang := a * TAU / 36.0
		tube(g, BB + Vector3(-0.045, sin(ang) * 0.095, cos(ang) * 0.095), BB + Vector3(-0.045, sin(ang + TAU / 36.0) * 0.095, cos(ang + TAU / 36.0) * 0.095), 0.008, cr)
	var bot := BB + dt * 0.35 + Vector3(0, 0.045, -0.005)
	tube(g, bot, bot + dt.normalized() * 0.2, 0.033, Color(0.92, 0.92, 0.94))
	return _grid_to_mesh_data(g)

const VS_WHEEL := 0.01

## a wheel from the circle itself (not from straight pieces), at 1 cm voxels so the edge steps are small.
## Centred on the axle, in the y-z plane, voxel size VS_WHEEL.
func wheel(paint: Dictionary) -> Dictionary:
	var g := {}
	var rim: Color = paint.rims; var wall: Color = paint.wall
	var tyre := Color(0.06, 0.06, 0.07)
	var hub := Color(0.25, 0.25, 0.27)
	var v := VS_WHEEL
	var n := int(ceil(R_WHEEL / v)) + 1
	for iy in range(-n, n):
		for iz in range(-n, n):
			var y := (iy + 0.5) * v; var z := (iz + 0.5) * v
			var r := sqrt(y * y + z * z)
			for ix in range(-6, 6):
				var x := (ix + 0.5) * v
				var col = null
				# tyre: round cross-section 25 mm wide, tread on the outside
				var tc := R_WHEEL - 0.0125
				if Vector2(r - tc, x).length() <= 0.0135:
					col = tyre if r > R_WHEEL - 0.008 else wall
				# deep rim (50 mm), a little wider than the tyre where they meet
				elif r <= R_WHEEL - 0.02 and r >= R_WHEEL - 0.07 and absf(x) <= 0.0135 - (R_WHEEL - 0.02 - r) * 0.08:
					col = rim
				# hub and flanges
				elif r <= 0.022 and absf(x) <= 0.05:
					col = hub
				elif r <= 0.035 and absf(absf(x) - 0.03) <= 0.006:
					col = hub
				if col != null:
					var c: Color = col
					g[Vector3i(ix, iy, iz)] = [c.r, c.g, c.b, 1]
	# axle through to the fork ends / dropouts, so the frame meets the wheel
	var axle := Color(0.6, 0.61, 0.63)
	for ix in range(-7, 7):
		for iy in range(-1, 1):
			for iz in range(-1, 1):
				g[Vector3i(ix, iy, iz)] = [axle.r, axle.g, axle.b, 1]
	# spokes: 24 steel spokes from the two hub flanges to the rim, crossing a little (tangent lacing)
	var steel := Color(0.72, 0.73, 0.75)
	var r_in := R_WHEEL - 0.068
	for k in 24:
		var flange := 0.03 if k % 2 == 0 else -0.03
		var a0 := k * TAU / 24.0
		var a1 := a0 + (0.12 if k % 4 < 2 else -0.12)
		var from := Vector3(flange, sin(a0) * 0.033, cos(a0) * 0.033)
		var to := Vector3(0, sin(a1) * r_in, cos(a1) * r_in)
		var L := from.distance_to(to)
		var steps := int(L / (v * 0.4))
		for i in steps + 1:
			var q := from.lerp(to, float(i) / steps)
			var key := Vector3i(floori(q.x / v), floori(q.y / v), floori(q.z / v))
			if not g.has(key): g[key] = [steel.r, steel.g, steel.b, 1]
	return g

func cranks() -> Dictionary:
	# around the bottom bracket axle (local origin), right arm pointing down (-y) at angle 0; left arm opposite
	var g := {}
	var c := Color(0.12, 0.12, 0.13)
	tube(g, Vector3(-0.06, 0, 0), Vector3(-0.06, -CRANK, 0), 0.012, c)
	tube(g, Vector3(0.06, 0, 0), Vector3(0.06, CRANK, 0), 0.012, c)
	tube(g, Vector3(-0.065, 0, 0), Vector3(0.065, 0, 0), 0.012, c)
	return _grid_to_mesh_data(g)

func pedal() -> Dictionary:
	var g := {}
	box(g, Vector3(0, 0, 0), Vector3(0.045, 0.008, 0.04), Color(0.1, 0.1, 0.11))
	return _grid_to_mesh_data(g)
