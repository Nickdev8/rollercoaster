extends Node2D

# adaptive smoothing and drawing
@export var resolution:      float   = 50.0  # target pixels per segment and input threshold
@export var track_texture:  Texture2D
@export var rail_width:     float   = 30.0
@export var uv_region:      Rect2   = Rect2(0,0,1,1)

# cart settings
@export var cart_count:     int     = 3
@export var cart_spacing:   float   = 150.0

# physics constants
const G: float = 800.0                 # gravitational acceleration (px/s^2)
@export var drag_coeff:  float = 0.001  # low linear drag for high momentum
@export var initial_speed: float = 0.0
@export var max_speed:    float = 5000.0 # clamp for runaway tracks

# internal state
var points:       Array[Vector2] = []
var is_drawing:   bool          = false
var last_point:   Vector2       = Vector2.ZERO
var carts:        Array = []  # entries: {"node": Node2D, "offset": float, "speed": float}

# camera control
var cam: Camera2D
var is_panning:   bool

@onready var cart_scene: PackedScene = preload("res://scenes/cart.tscn")

func _ready():
	# ensure Camera2D exists and is current
	if has_node("Camera2D"):
		cam = $Camera2D
	else:
		cam = Camera2D.new()
		add_child(cam)
	cam.make_current()
	# build cropped AtlasTexture
	if track_texture:
		var atlas = AtlasTexture.new()
		atlas.atlas = track_texture
		var ts = track_texture.get_size()
		atlas.region = Rect2(uv_region.position * ts, uv_region.size * ts)
		atlas.filter_clip = true
		track_texture = atlas

	# instantiate carts
	for i in range(cart_count):
		var cart_node = cart_scene.instantiate() as Node2D
		add_child(cart_node)
		carts.append({
			"node": cart_node,
			"offset": i * cart_spacing,
			"speed": initial_speed
		})

func _input(event):
	# adaptive min_distance based on resolution
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
		if mp.distance_to(last_point) >= resolution:
			last_point = mp
			points.append(last_point)
			queue_redraw()

	# clear and reset carts
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_C:
				points.clear()
				queue_redraw()
			KEY_R:
				for i in range(carts.size()):
					carts[i].offset = i * cart_spacing
					carts[i].speed = initial_speed

	# camera panning with right mouse button
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		is_panning = event.pressed
	elif event is InputEventMouseMotion and is_panning:
		cam.position -= event.relative / cam.zoom

	# zoom with scroll wheel
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				cam.zoom *= 1.1
			MOUSE_BUTTON_WHEEL_DOWN:
				cam.zoom *= 0.9

func _draw():
	var track_pts = get_track_points()
	if track_pts.size() < 2 or not track_texture:
		return

	var ts      = track_texture.get_size()
	var region  = uv_region.size * ts
	var pw      = region.x
	var ph      = region.y

	for i in range(track_pts.size() - 1):
		var a = track_pts[i]
		var b = track_pts[i+1]
		var seg_len = a.distance_to(b)
		if seg_len <= 0:
			continue
		var ang    = (b - a).angle()
		var slices = int(ceil(seg_len / pw))
		draw_set_transform(a, ang, Vector2.ONE)
		for k in range(slices):
			var x_off = k * pw
			var w     = min(pw, seg_len - x_off)
			if w <= 0:
				break
			var src = Rect2(uv_region.position * ts, Vector2(w, ph))
			var dst = Rect2(Vector2(x_off,0), Vector2(w, rail_width))
			draw_texture_rect_region(track_texture, dst, src, Color(1,1,1), false, true)
		draw_set_transform_matrix(Transform2D.IDENTITY)

func _process(delta):
	var track_pts = get_track_points()
	if track_pts.size() < 2:
		return

	var length = total_length(track_pts)
	for cart in carts:
		var node = cart.node as Node2D
		var sample = sample_track(track_pts, cart.offset)
		node.global_position = sample[0]
		node.rotation = sample[1]

		var slope_accel = G * sin(node.rotation)
		var drag_force = drag_coeff * cart.speed
		cart.speed = clamp(cart.speed + (slope_accel - drag_force) * delta, -max_speed, max_speed)
		cart.offset += cart.speed * delta

		if cart.offset >= length:
			cart.offset -= length
		elif cart.offset < 0:
			cart.offset += length

func get_track_points() -> PackedVector2Array:
	var pts = PackedVector2Array(points)
	if pts.size() < 2:
		return PackedVector2Array()

	# compute total length for adaptive segments
	var length = total_length(pts)
	var segs   = max(1, int(length / resolution))

	# Catmull-Rom smoothing with adaptive segment count
	var smooth = PackedVector2Array()
	for i in range(pts.size() - 1):
		var p0 = pts[i-1] if i>0 else pts[i]
		var p1 = pts[i]
		var p2 = pts[i+1]
		var p3 = pts[i+2] if i+2<pts.size() else pts[i+1]
		for j in range(segs + 1):
			var t  = j / float(segs)
			var t2 = t*t; var t3 = t2*t
			smooth.append(p0 * (-0.5*t3 + t2 - 0.5*t)
						+ p1 * ( 1.5*t3 - 2.5*t2 + 1.0)
						+ p2 * (-1.5*t3 + 2.0*t2 + 0.5*t)
						+ p3 * ( 0.5*t3 - 0.5*t2))

	# preserve spacing
	var clamped = PackedVector2Array()
	clamped.append(smooth[0])
	for i in range(1, smooth.size()):
		var prev = clamped[i-1]
		var curr = smooth[i]
		var d = curr.distance_to(prev)
		clamped.append(prev if d <= 0 else prev + (curr - prev).normalized() * d)
	return clamped

func total_length(pts: PackedVector2Array) -> float:
	var sum = 0.0
	for i in range(pts.size() - 1):
		sum += pts[i].distance_to(pts[i+1])
	return sum

func sample_track(pts: PackedVector2Array, offset: float) -> Array:
	var travelled = 0.0
	for i in range(pts.size() - 1):
		var a = pts[i]; var b = pts[i+1]
		var seg = a.distance_to(b)
		if travelled + seg >= offset:
			var t = (offset - travelled) / seg
			return [a.lerp(b, t), (b - a).angle()]
		travelled += seg
	return [pts[pts.size()-1], 0.0]
