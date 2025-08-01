extends Node2D

# --- Adaptive smoothing & sampling ---
@export var resolution: float = 50.0          # points per segment for interpolation
@export var smoothing_factor: float = 0.1     # for exponential smoothing of G readings

# --- Input drawing thresholds ---
@export var input_threshold: float = 50.0

# --- Rail drawing parameters ---
@export var rail_width: float = 2.0
@export var rail_offset: float = 5.0

# --- Cart & detachment settings ---
@export var cart_count: int = 3
@export var cart_spacing: float = 150.0
@export var detach_threshold_g: float = 3.0   # detach at 3 G

# --- Cartoon ejection settings ---
@export var eject_force_multiplier: float = 3.0
@export var eject_spin_range: Vector2 = Vector2(5.0, 15.0)
@export var cartoon_tween_time: float = 0.5   # duration of squash/stretch tween

# --- Physics constants & conversions ---
const REAL_G: float = 9.81                   # m/s²
@export var px_to_m: float = 0.01            # 1px = 1cm = 0.01 m
@export var drag_linear: float = 0.1         # linear drag (kg/s)
@export var drag_quadratic: float = 0.01     # quadratic drag (kg/m)
@export var mass: float = 1.0                # cart mass (kg)

@export var initial_speed: float = 0.0       # in px/s
@export var max_speed: float = 5000.0        # in px/s

# --- Internal state ---
var points := PackedVector2Array()
var is_drawing := false
var last_point := Vector2.ZERO

var carts: Array = []                        # each is a Dictionary
var highest_g_overall := 0.0

# --- Camera ---
var cam: Camera2D
var is_panning := false

@onready var cart_scene: PackedScene = preload("res://scenes/cart.tscn")

func _ready():
	# Setup camera
	if has_node("Camera2D"):
		cam = $Camera2D
	else:
		cam = Camera2D.new()
		add_child(cam)
	cam.make_current()

	_reset_carts()

func _reset_carts():
	# Remove old carts
	for c in carts:
		if is_instance_valid(c.node):
			c.node.queue_free()
	carts.clear()
	# Spawn new carts
	for i in cart_count:
		var cart_node = cart_scene.instantiate() as Node2D
		add_child(cart_node)
		carts.append({
			"node": cart_node,
			"offset": float(i) * cart_spacing,
			"speed": initial_speed,
			"smoothed_g": 0.0,
			"max_g": 0.0,
			"detached": false
		})

func _input(event):
	# Track drawing
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

	# Clear or reset
	if event is InputEventKey and event.pressed:
		match event.key:
			KEY_C:
				points.clear()
				queue_redraw()
			KEY_R:
				_reset_carts()

	# Camera control
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				is_panning = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				cam.zoom *= 1.1
			MOUSE_BUTTON_WHEEL_DOWN:
				cam.zoom *= 0.9
	elif event is InputEventMouseMotion and is_panning:
		cam.position -= event.relative / cam.zoom

func _draw():
	var pts = _get_track_points()
	if pts.size() < 2:
		return

	var left_pts = []
	var right_pts = []
	for i in pts.size():
		var p = pts[i]
		var dir = ((pts[i + 1] - p).normalized() if i < pts.size() - 1 else (p - pts[i - 1]).normalized())
		var perp = Vector2(-dir.y, dir.x)
		left_pts.append(p + perp * rail_offset)
		right_pts.append(p - perp * rail_offset)
	draw_polyline(left_pts, Color.BLACK, rail_width)
	draw_polyline(right_pts, Color.BLACK, rail_width)

func _process(delta: float) -> void:
	var pts = _get_track_points()
	if pts.size() < 2:
		return
	var total_len = _total_length(pts)

	for cart in carts:
		if cart.detached:
			continue

		# Sample track at cart.offset
		var s = _sample_track(pts, cart.offset)
		_update_cart_node(cart, s)

		# Physics in meters
		var v_m = cart.speed * px_to_m
		var tangent = Vector2(cos(s.angle), sin(s.angle))
		var normal = Vector2(-tangent.y, tangent.x)

		# Curvature → R
		var curvature = _compute_curvature(pts, s.idx, s.seg_len)
		var radius = 1.0 / curvature if curvature > 0.0 else INF

		# Tangential acceleration
		var F_gravity_t = mass * REAL_G * cos(PI/2 - s.angle)
		var F_drag = drag_linear * v_m + drag_quadratic * v_m * abs(v_m)
		var a_tangent = (F_gravity_t - F_drag) / mass

		# Centripetal accel
		var a_normal = v_m * v_m / radius if radius < INF else 0.0

		var a_vec = tangent * a_tangent + normal * a_normal
		var g_total = a_vec.length() / REAL_G

		# Smooth & record
		cart.smoothed_g = lerp(cart.smoothed_g, g_total, clamp(smoothing_factor, 0, 1))
		cart.max_g = max(cart.max_g, cart.smoothed_g)
		highest_g_overall = max(highest_g_overall, cart.smoothed_g)

		# Move along track
		cart.speed = clamp(cart.speed + a_tangent * delta / px_to_m, -max_speed, max_speed)
		cart.offset = (cart.offset + cart.speed * delta + total_len) % total_len

		# Detach if too many Gs
		if abs(cart.speed) > 0.1 and cart.smoothed_g > detach_threshold_g:
			cart.detached = true
			_detach_cart(cart, s)

func _detach_cart(cart: Dictionary, s: Dictionary) -> void:
	var old = cart.node
	var body = RigidBody2D.new()
	body.mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	body.global_position = old.global_position
	body.global_rotation = old.global_rotation

	# Cartoon impulse
	var tangent = Vector2(cos(s.angle), sin(s.angle))
	var outward = Vector2(-sin(s.angle), cos(s.angle))
	var force = (tangent + outward).normalized() * cart.speed * eject_force_multiplier
	body.apply_central_impulse(force * px_to_m * mass)

	# Random spin
	body.angular_velocity = randf_range(eject_spin_range.x, eject_spin_range.y) * (1 if randf() < 0.5 else -1)

	# Move visuals under physics body
	for child in old.get_children():
		old.remove_child(child)
		body.add_child(child)
	get_parent().add_child(body)
	old.queue_free()

	# Cartoon squash & stretch
	var tween = body.create_tween()
	tween.tween_property(body, "scale", Vector2(1.5, 0.5), cartoon_tween_time * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(body, "scale", Vector2(1, 1), cartoon_tween_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

	# Particle burst
	var particles = CPUParticles2D.new()
	particles.lifetime = cartoon_tween_time
	particles.one_shot = true
	particles.amount = 20
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	particles.speed_scale = 5
	particles.process_material = ParticleProcessMaterial.new()
	particles.global_position = body.global_position
	body.add_child(particles)
	particles.emitting = true

# --- Track helpers ---

func _compute_curvature(pts: PackedVector2Array, idx: int, seg_len: float) -> float:
	if idx < 1 or idx > pts.size() - 2:
		return 0.0
	var p1 = pts[idx - 1]
	var p2 = pts[idx]
	var p3 = pts[idx + 1]
	var a1 = (p2 - p1).angle()
	var a2 = (p3 - p2).angle()
	return abs(wrapf(a2 - a1, -PI, PI)) / max(seg_len * px_to_m, 0.001)

func _update_cart_node(cart: Dictionary, s: Dictionary) -> void:
	cart.node.global_position = s.pos
	cart.node.rotation = s.angle
	cart.node.set("current_g", cart.smoothed_g)

func _get_track_points() -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var length = _total_length(points)
	var segs = max(1, int(length / resolution))
	var smooth = PackedVector2Array()
	for i in points.size() - 1:
		var p0 = points[i - 1] if  i > 0 else points[i]
		var p1 = points[i]
		var p2 = points[i + 1]
		var p3 = points[i + 2] if i + 2 < points.size() else points[i + 1]
		for j in segs + 1:
			var t = j / float(segs)
			smooth.append(_catmull_rom(p0, p1, p2, p3, t))
	return smooth

func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 = t * t
	var t3 = t2 * t
	return p0 * (-0.5 * t3 + t2 - 0.5 * t) \
		 + p1 * ( 1.5 * t3 - 2.5 * t2 + 1.0) \
		 + p2 * (-1.5 * t3 + 2.0 * t2 + 0.5 * t) \
		 + p3 * ( 0.5 * t3 - 0.5 * t2)

func _total_length(pts: PackedVector2Array) -> float:
	var sum = 0.0
	for i in pts.size() - 1:
		sum += pts[i].distance_to(pts[i + 1])
	return sum

func _sample_track(pts: PackedVector2Array, offset: float) -> Dictionary:
	var traveled = 0.0
	var L = _total_length(pts)
	var off = (offset % L)
	for i in pts.size() - 1:
		var a = pts[i]
		var b = pts[i + 1]
		var seg = a.distance_to(b)
		if traveled + seg >= off:
			var t = (off - traveled) / seg
			return {
				"pos": a.lerp(b, t),
				"angle": (b - a).angle(),
				"idx": i,
				"seg_len": seg
			}
		traveled += seg
	return {
		"pos": pts[pts.size() - 1],
		"angle": 0.0,
		"idx": pts.size() - 2,
		"seg_len": 0.0
	}
