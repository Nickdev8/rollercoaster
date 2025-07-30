extends Node2D

@export var segments:      int    = 12
@export var min_distance:  float  = 10.0
@export var track_texture: Texture2D
@export var rail_width:    float  = 30.0
@export var uv_region:     Rect2  = Rect2(0,0,1,1)

# speed in pixels per second
@export var card_speed:    float  = 100.0

# internal
var points:       Array[Vector2] = []
var is_drawing:   bool          = false
var last_point:   Vector2       = Vector2.ZERO
var card_offset:  float         = 0.0   # how far along the track our card is

@onready var card: Sprite2D = $Card

func _ready():
	# build our cropped AtlasTexture exactly as before
	if track_texture:
		var atlas = AtlasTexture.new()
		atlas.atlas = track_texture
		var ts = track_texture.get_size()
		atlas.region = Rect2(uv_region.position * ts, uv_region.size * ts)
		atlas.filter_clip = true
		track_texture = atlas

func _input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			is_drawing = true
			last_point  = event.position
			points.append(last_point)
			queue_redraw()
		else:
			is_drawing = false
	elif event is InputEventMouseMotion and is_drawing:
		if event.position.distance_to(last_point) >= min_distance:
			last_point = event.position
			points.append(last_point)
			queue_redraw()

func _draw():
	var track_pts = get_track_points()
	if track_pts.size() < 2 or not track_texture:
		return

	# tile the texture exactly as before, using track_pts…
	var ts      = track_texture.get_size()
	var region  = uv_region.size * ts
	var pw      = region.x
	var ph      = region.y

	for i in range(track_pts.size() - 1):
		var a = track_pts[i]
		var b = track_pts[i+1]
		var seg_len = a.distance_to(b)
		if seg_len <= 0: continue

		var ang = (b - a).angle()
		var slices = int(ceil(seg_len / pw))

		draw_set_transform(a, ang, Vector2.ONE)
		for k in range(slices):
			var x_off = k * pw
			var w = min(pw, seg_len - x_off)
			if w <= 0: break

			var src = Rect2(uv_region.position * ts, Vector2(w, ph))
			var dst = Rect2(Vector2(x_off,0), Vector2(w, rail_width))
			draw_texture_rect_region(track_texture, dst, src, Color(1,1,1), false, true)
		draw_set_transform_matrix(Transform2D.IDENTITY)

func _process(delta):
	var track_pts = get_track_points()
	if track_pts.size() < 2:
		return

	var length = total_length(track_pts)
	card_offset += card_speed * delta
	if card_offset >= length:
		card_offset -= length   # wraps back around
	# (if your card_speed*delta could be > length, you might want a while‑loop)

	var result = sample_track(track_pts, card_offset)
	card.global_position = result[0]
	card.rotation        = result[1]


# — Helpers —

# 1) Build your full list of smoothed + slope‑clamped points
func get_track_points() -> PackedVector2Array:
	var smooth = PackedVector2Array()
	if points.size() < 2:
		return smooth

	# Catmull–Rom
	for i in range(points.size() - 1):
		var p0 = points[i-1] if i>0 else points[i]
		var p1 = points[i]
		var p2 = points[i+1]
		var p3 = points[i+2] if i+2<points.size() else points[i+1]
		for j in range(segments+1):
			var t = j/float(segments)
			var t2 = t*t; var t3 = t2*t
			var f1 = -0.5*t3 +    t2 - 0.5*t
			var f2 =  1.5*t3 -2.5*t2 +1
			var f3 = -1.5*t3 +2*t2 +0.5*t
			var f4 =  0.5*t3 -0.5*t2
			smooth.append(p0*f1 + p1*f2 + p2*f3 + p3*f4)

	# slope‑clamp
	var clamped = PackedVector2Array()
	clamped.append(smooth[0])
	for i in range(1, smooth.size()):
		var prev = clamped[i-1]
		var orig = smooth[i]
		var d = orig.distance_to(prev)
		if d <= 0:
			clamped.append(prev)
		else:
			clamped.append(prev + (orig - prev).normalized() * d)
	return clamped

# 2) Compute total length
func total_length(pts: PackedVector2Array) -> float:
	var sum = 0.0
	for i in range(pts.size()-1):
		sum += pts[i].distance_to(pts[i+1])
	return sum

# 3) Sample a position+angle at a given offset (in px) along the pts
func sample_track(pts: PackedVector2Array, offset: float):
	var travelled = 0.0
	for i in range(pts.size() - 1):
		var a = pts[i]
		var b = pts[i+1]
		var seg = a.distance_to(b)
		if travelled + seg >= offset:
			var local_t = (offset - travelled) / seg
			var pos = a.lerp(b, local_t)
			var ang = (b - a).angle()
			return [pos, ang]
		travelled += seg
	# if somehow past the end:
	return [pts[pts.size() - 1], 0.0]
