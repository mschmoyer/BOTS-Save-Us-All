/// @description Repulsor blast

var replusor_range = range
var repulsor_push = push
var repulsor = self;
with(obj_enemy) {
	if (distance_to_object(repulsor) < replusor_range) 
	{
		x -= repulsor_push ; 
		y -= repulsor_push ; 
	}
}

alarm[0] = push_timer;