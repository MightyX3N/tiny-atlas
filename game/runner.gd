class_name Runner
extends Node3D
## The player on foot, for walking pads, treadmills and footpods: a Kenney character with Kenney's run
## animation. Faces +Z.

const SKIN := "res://assets/chars/skaterMaleA.png"

var body: Node3D
var anim: AnimationPlayer

func _ready() -> void:
	body = _skinned("res://assets/chars/run.fbx"); add_child(body)
	# the run file has the skeleton and the animation; the character's mesh comes from characterMedium
	var src: Node3D = _skinned("res://assets/chars/characterMedium.fbx")
	var sk: Skeleton3D = body.find_children("*", "Skeleton3D", true, false)[0]
	var m: MeshInstance3D = src.find_children("*", "MeshInstance3D", true, false)[0]
	m.get_parent().remove_child(m); m.owner = null; sk.add_child(m); m.skeleton = NodePath("..")
	src.free()
	var mat := StandardMaterial3D.new(); mat.albedo_texture = load(SKIN); m.material_override = mat
	anim = body.find_children("*", "AnimationPlayer", true, false)[0]
	var a := anim.get_animation("Root|Run")
	if a: a.loop_mode = Animation.LOOP_LINEAR
	anim.play("Root|Run")
	# 1.75 m tall, feet on the ground
	var box := _aabb(body)
	body.scale *= 1.75 / box.size.y
	body.position.y -= _aabb(body).position.y - global_position.y

static func _skinned(path: String) -> Node3D:
	var n: Node3D = (load(path) as PackedScene).instantiate()
	# Godot 4.6's FBX import can leave the mesh without its skeleton link (it then shows the rest pose):
	# point every skinned mesh at the model's skeleton
	var skels := n.find_children("*", "Skeleton3D", true, false)
	if not skels.is_empty():
		for c in n.find_children("*", "MeshInstance3D", true, false):
			var mi := c as MeshInstance3D
			if mi.skin != null and mi.get_node_or_null(mi.skeleton) == null:
				mi.skeleton = mi.get_path_to(skels[0])
	return n

static func _aabb(node: Node) -> AABB:
	var out := AABB(); var first := true
	for c in node.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = (c as MeshInstance3D).global_transform * (c as MeshInstance3D).get_aabb()
		if first: out = a; first = false
		else: out = out.merge(a)
	return out

## cadence is ignored; speed in m/s (the run animation's natural pace is about 9 km/h)
func animate(_dt: float, _cadence: float, speed: float) -> void:
	anim.speed_scale = clampf(speed / 2.5, 0.0, 2.2) if speed >= 0.1 else 0.0
