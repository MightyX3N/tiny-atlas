class_name Kits
extends RefCounted
## Cycling kits and bike paints, unlocked by riding. Progress is saved in user://progress.json.
##
## A kit: jersey (base, accent, pattern), shorts, socks, shoes, gloves, helmet, glasses.
## A paint: frame, accent, rims, tyres' sidewalls, bar tape, saddle.
## unlock: { "km": total distance } or { "rides": finished rides }; {} = from the start.

const KITS := [
	{ "id": "club", "name": "Club Blue", "unlock": {},
	  "jersey": Color(0.12, 0.32, 0.72), "accent": Color(0.95, 0.95, 0.95), "pattern": "band",
	  "shorts": Color(0.06, 0.07, 0.1), "socks": Color(0.95, 0.95, 0.95), "shoes": Color(0.95, 0.95, 0.95),
	  "gloves": Color(0.1, 0.1, 0.12), "helmet": Color(0.12, 0.32, 0.72), "glasses": Color(0.08, 0.08, 0.1) },
	{ "id": "classic", "name": "Classic Red", "unlock": { "km": 5 },
	  "jersey": Color(0.78, 0.1, 0.1), "accent": Color(0.96, 0.96, 0.96), "pattern": "sleeves",
	  "shorts": Color(0.06, 0.06, 0.07), "socks": Color(0.96, 0.96, 0.96), "shoes": Color(0.06, 0.06, 0.07),
	  "gloves": Color(0.78, 0.1, 0.1), "helmet": Color(0.96, 0.96, 0.96), "glasses": Color(0.6, 0.1, 0.1) },
	{ "id": "night", "name": "Night Rider", "unlock": { "rides": 3 },
	  "jersey": Color(0.06, 0.06, 0.07), "accent": Color(0.6, 1.0, 0.1), "pattern": "stripe",
	  "shorts": Color(0.05, 0.05, 0.06), "socks": Color(0.6, 1.0, 0.1), "shoes": Color(0.06, 0.06, 0.07),
	  "gloves": Color(0.06, 0.06, 0.07), "helmet": Color(0.06, 0.06, 0.07), "glasses": Color(0.5, 0.9, 0.1) },
	{ "id": "climber", "name": "Mountain Dots", "unlock": { "km": 25 },
	  "jersey": Color(0.97, 0.97, 0.97), "accent": Color(0.82, 0.08, 0.1), "pattern": "dots",
	  "shorts": Color(0.06, 0.06, 0.07), "socks": Color(0.97, 0.97, 0.97), "shoes": Color(0.97, 0.97, 0.97),
	  "gloves": Color(0.82, 0.08, 0.1), "helmet": Color(0.97, 0.97, 0.97), "glasses": Color(0.82, 0.08, 0.1) },
	{ "id": "leader", "name": "Yellow Leader", "unlock": { "km": 50 },
	  "jersey": Color(1.0, 0.82, 0.05), "accent": Color(0.06, 0.06, 0.07), "pattern": "collar",
	  "shorts": Color(0.06, 0.06, 0.07), "socks": Color(1.0, 0.82, 0.05), "shoes": Color(1.0, 0.82, 0.05),
	  "gloves": Color(0.06, 0.06, 0.07), "helmet": Color(1.0, 0.82, 0.05), "glasses": Color(0.06, 0.06, 0.07) },
	{ "id": "sprinter", "name": "Green Sprinter", "unlock": { "km": 100 },
	  "jersey": Color(0.1, 0.62, 0.25), "accent": Color(0.96, 0.96, 0.96), "pattern": "split",
	  "shorts": Color(0.06, 0.06, 0.07), "socks": Color(0.1, 0.62, 0.25), "shoes": Color(0.96, 0.96, 0.96),
	  "gloves": Color(0.1, 0.62, 0.25), "helmet": Color(0.1, 0.62, 0.25), "glasses": Color(0.96, 0.96, 0.96) },
	{ "id": "champion", "name": "Rainbow Champion", "unlock": { "km": 250 },
	  "jersey": Color(0.97, 0.97, 0.97), "accent": Color(0.97, 0.97, 0.97), "pattern": "rainbow",
	  "shorts": Color(0.97, 0.97, 0.97), "socks": Color(0.97, 0.97, 0.97), "shoes": Color(0.97, 0.97, 0.97),
	  "gloves": Color(0.97, 0.97, 0.97), "helmet": Color(0.97, 0.97, 0.97), "glasses": Color(0.2, 0.3, 0.8) },
]

const PAINTS := [
	{ "id": "carbon", "name": "Raw Carbon", "unlock": {},
	  "frame": Color(0.09, 0.09, 0.1), "accent": Color(0.85, 0.85, 0.85), "rims": Color(0.07, 0.07, 0.08),
	  "wall": Color(0.07, 0.07, 0.08), "tape": Color(0.07, 0.07, 0.08), "saddle": Color(0.07, 0.07, 0.08) },
	{ "id": "red", "name": "Racing Red", "unlock": { "km": 15 },
	  "frame": Color(0.75, 0.06, 0.06), "accent": Color(0.97, 0.97, 0.97), "rims": Color(0.07, 0.07, 0.08),
	  "wall": Color(0.07, 0.07, 0.08), "tape": Color(0.97, 0.97, 0.97), "saddle": Color(0.07, 0.07, 0.08) },
	{ "id": "blue", "name": "Team Blue", "unlock": { "km": 40 },
	  "frame": Color(0.1, 0.28, 0.7), "accent": Color(1.0, 0.82, 0.05), "rims": Color(0.07, 0.07, 0.08),
	  "wall": Color(0.62, 0.48, 0.3), "tape": Color(0.07, 0.07, 0.08), "saddle": Color(0.07, 0.07, 0.08) },
	{ "id": "pearl", "name": "Pearl White", "unlock": { "km": 75 },
	  "frame": Color(0.95, 0.95, 0.93), "accent": Color(0.08, 0.08, 0.1), "rims": Color(0.55, 0.56, 0.58),
	  "wall": Color(0.62, 0.48, 0.3), "tape": Color(0.95, 0.95, 0.93), "saddle": Color(0.95, 0.95, 0.93) },
	{ "id": "gold", "name": "Gold", "unlock": { "km": 150 },
	  "frame": Color(0.8, 0.62, 0.18), "accent": Color(0.08, 0.08, 0.1), "rims": Color(0.8, 0.62, 0.18),
	  "wall": Color(0.07, 0.07, 0.08), "tape": Color(0.08, 0.08, 0.1), "saddle": Color(0.08, 0.08, 0.1) },
]

const SAVE := "user://progress.json"
var total_km := 0.0
var rides := 0
var kit_id := "club"
var paint_id := "carbon"

func _init() -> void:
	load_progress()

func load_progress() -> void:
	var txt := FileAccess.get_file_as_string(SAVE)
	var d = JSON.parse_string(txt) if txt != "" else null
	if d is Dictionary:
		total_km = float(d.get("total_km", 0.0)); rides = int(d.get("rides", 0))
		kit_id = str(d.get("kit", "club")); paint_id = str(d.get("paint", "carbon"))

func save() -> void:
	var f := FileAccess.open(SAVE, FileAccess.WRITE)
	if f: f.store_string(JSON.stringify({ "total_km": total_km, "rides": rides, "kit": kit_id, "paint": paint_id }))

func is_unlocked(item: Dictionary) -> bool:
	var u: Dictionary = item.unlock
	if u.has("km") and total_km < float(u.km): return false
	if u.has("rides") and rides < int(u.rides): return false
	return true

func requirement(item: Dictionary) -> String:
	var u: Dictionary = item.unlock
	if u.has("km"): return "ride %d km in total (%.1f / %d)" % [int(u.km), total_km, int(u.km)]
	if u.has("rides"): return "finish %d rides (%d / %d)" % [int(u.rides), rides, int(u.rides)]
	return ""

static func find(list: Array, id: String) -> Dictionary:
	for it in list:
		if it.id == id: return it
	return list[0]

func kit() -> Dictionary: return find(KITS, kit_id)
func paint() -> Dictionary: return find(PAINTS, paint_id)

## add riding; returns the names of anything that just unlocked
func add(km: float, finished_ride: bool) -> Array:
	var before := []
	for it in KITS + PAINTS: before.append(is_unlocked(it))
	total_km += km
	if finished_ride: rides += 1
	var newly := []
	var all := KITS + PAINTS
	for i in all.size():
		if not before[i] and is_unlocked(all[i]): newly.append(all[i].name)
	save()
	return newly
