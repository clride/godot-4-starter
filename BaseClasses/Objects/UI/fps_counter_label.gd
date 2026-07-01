extends Label

func _process(_delta: float) -> void:
	text = str(int(Engine.get_frames_per_second())) + " FPS"
