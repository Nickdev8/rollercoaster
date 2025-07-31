extends Node2D

var images = [
	"res://assets/human1.png",
	"res://assets/human2.png",
	"res://assets/human3.png",
	"res://assets/human4.png",
	"res://assets/human5.png"
]

@onready var human_1: Sprite2D = $Human1
@onready var human_2: Sprite2D = $Human2

func _ready() -> void:
	randomize()
	# pick the first texture
	var tex1: Texture2D = load(images.pick_random())
	human_1.texture = tex1

	# pick a second – if it equals the first, keep picking
	var tex2: Texture2D = load(images.pick_random())
	while tex2 == tex1:
		tex2 = load(images.pick_random())
	human_2.texture = tex2
