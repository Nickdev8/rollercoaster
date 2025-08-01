
extends Node2D

# adaptive smoothing
@export var resolution: float = 50.0

# input sampling threshold
@export var input_threshold: float = 50.0

# rail drawing
@export var rail_width: float = 2.0
@export var rail_offset: float = 5.0

# cart settings
@export var cart_count: int = 3
@export var cart_spacing: float = 150.0
@export var detach_threshold: float = 2.0  # G-force at which to detach

# physics constants
const G: float = 800.0  # px/s²
@export var drag_coeff: float = 0.001
@export var initial_speed: float = 0.0
@export var max_speed: float = 5000.0

# internal state
var points: Array[Vector2] = []
var is_drawing: bool = false
var last_point: Vector2 = Vector2.ZERO
var carts: Array = []  # each: { node, offset, speed, max_g, detached }
var highest_g_overall: float = 0.0

# camera
var cam: Camera2D
var is_panning: bool = false

@onready var cart_scene: PackedScene = preload("res://scenes/cart.tscn")

func _ready():
	# camera setup
	cam = $Camera2D if has_node("Camera2D") else Camera2D.new()
	if !has_node("Camera2D"):
		add_child(cam)
	cam.make_current()

	# instantiate carts
	for i in range(cart_count):
		var cart_node = cart_scene.instantiate() as Node2D
		add_child(cart_node)
		carts.append({
			"node": cart_node,
			"offset": i * cart_spacing,
			"speed": initial_speed,
			"max_g": 9,
			"detached": false
		})

func _input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			is_drawing = true
			last_point = get_global_mouse_position()
			points.append(last_point)
			queue_redraw()
		else:
			is_drawing = false
	elif event is InputEventMouseMotion and is_drawing:
		var mp = get_global_mouse_position()
		if mp.distance_to(last_point) >= input_threshold:
			last_point = mp
			points.append(mp)
			queue_redraw()

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_C:
				points.clear(); queue_redraw()
			KEY_R:
				for j in range(carts.size()):
					var c = carts[j]
					c.offset = j * cart_spacing
					c.speed = initial_speed
					c.max_g = 9
					c.detached = false
					# reset nodes
					if !is_instance_valid(c.node):
						var new_node = cart_scene.instantiate() as Node2D
						add_child(new_node)
						c.node = new_node

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		is_panning = event.pressed
	elif event is InputEventMouseMotion and is_panning:
		cam.position -= event.relative / cam.zoom

	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: cam.zoom *= 1.1
			MOUSE_BUTTON_WHEEL_DOWN: cam.zoom *= 0.9

func _draw():
	var pts = get_track_points()
	if pts.size() < 2:
		return

	var left_arr = PackedVector2Array()
	var right_arr = PackedVector2Array()
	for i in range(pts.size()):
		var p = pts[i]
		var dir = (pts[i+1] - p).normalized() if i < pts.size()-1 else (p - pts[i-1]).normalized()
		var perp = Vector2(-dir.y, dir.x)
		left_arr.append(p + perp * rail_offset)
		right_arr.append(p - perp * rail_offset)

	draw_polyline(left_arr, Color.BLACK, rail_width)
	draw_polyline(right_arr, Color.BLACK, rail_width)

func _process(delta):
	var pts = get_track_points()
	if pts.size() < 2:
		return
	var length = total_length(pts)

	for i in range(carts.size()-1, -1, -1):
		var cart = carts[i]
		if cart.detached:
			continue

		var s = sample_track(pts, cart.offset)
		var pos = s.pos
		var angle = s.angle
		var segl = s.seg_len

		# update node transform
		var node = cart.node as Node2D
		node.global_position = pos
		node.rotation = angle

		# tangential accel
		var a_tangent = G * sin(angle) - drag_coeff * cart.speed

		# centripetal accel
		var curvature = 0.0
		if segl > 0.001 and s.idx < pts.size()-1:
			var next_ang = (pts[s.idx+2] - pts[s.idx+1]).angle() if s.idx < pts.size()-2 else angle
			var dθ = wrapf(next_ang - angle, -PI, PI)
			curvature = abs(dθ) / max(segl, 0.001)
		var a_centrip = clamp(cart.speed * cart.speed * curvature, -G*10, G*10)

		# normal accel
		var a_normal = G * cos(angle) + a_centrip

		# move along track
		cart.speed = clamp(cart.speed + a_tangent * delta, -max_speed, max_speed)
		cart.offset = fmod(cart.offset + cart.speed * delta + length, length)

		# compute G
		var g_total = sqrt(a_tangent*a_tangent + a_normal*a_normal) / G
		node.set("current_g", g_total)

		# update peaks
		cart.max_g = max(cart.max_g, g_total)
		highest_g_overall = max(highest_g_overall, g_total)

		# only detach if speed is non-zero
		if abs(cart.speed) > 0.1 and g_total > detach_threshold:
			cart.detached = true
			_detach_cart(cart, angle, g_total)

func _detach_cart(cart: Dictionary, angle: float, g_total: float) -> void:
	var old = cart.node as Node2D
	var body = RigidBody2D.new()
	body.global_position = old.global_position
	body.global_rotation = old.global_rotation
	var tangent = Vector2(cos(angle), sin(angle))
	var outward = Vector2(-sin(angle), cos(angle)) * max(g_total - 1, 0)
	var dir = (tangent + outward).normalized()
	body.linear_velocity = dir * cart.speed
	# reparent visuals
	for child in old.get_children():
		old.remove_child(child)
		body.add_child(child)
	get_parent().add_child(body)
	old.queue_free()

func get_track_points() -> PackedVector2Array:
	var pts0 = PackedVector2Array(points)
	if pts0.size() < 2:
		return PackedVector2Array()
	var length = total_length(pts0)
	var segs = max(1, int(length / resolution))
	var smooth = PackedVector2Array()
	for i in range(pts0.size()-1):
		var p0 = pts0[i-1] if i>0 else pts0[i]
		var p1 = pts0[i]; var p2 = pts0[i+1]
		var p3 = pts0[i+2] if i+2<pts0.size() else pts0[i+1]
		for j in range(segs+1):
			var t = j/float(segs); var t2=t*t; var t3=t2*t
			smooth.append(
				p0*(-0.5*t3 + t2 - 0.5*t) +
				p1*(1.5*t3 - 2.5*t2 + 1) +
				p2*(-1.5*t3 + 2*t2 + 0.5*t) +
				p3*(0.5*t3 - 0.5*t2)
			)
	var clamped = PackedVector2Array([smooth[0]])
	for i in range(1, smooth.size()):
		var prev = clamped[i-1]; var curr = smooth[i]
		var d = curr.distance_to(prev)
		clamped.append(prev if d <= 0 else prev + (curr - prev).normalized() * d)
	return clamped

func total_length(pts: PackedVector2Array) -> float:
	var sum = 0.0
	for i in range(pts.size()-1): sum += pts[i].distance_to(pts[i+1])
	return sum

func sample_track(pts: PackedVector2Array, offset: float) -> Dictionary:
	var traveled = 0.0
	for i in range(pts.size()-1):
		var a = pts[i]; var b = pts[i+1]
		var seg = a.distance_to(b)
		if traveled + seg >= offset:
			var t = (offset - traveled) / seg
			return {"pos": a.lerp(b, t), "angle": (b - a).angle(), "idx": i, "seg_len": seg}
		traveled += seg
	return {"pos": pts[pts.size()-1], "angle": 0.0, "idx": pts.size()-2, "seg_len": 0.0}
