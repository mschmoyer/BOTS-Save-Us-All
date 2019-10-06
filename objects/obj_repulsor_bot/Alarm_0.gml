/// @description Repulsor blast

sprite_index = 1;

var replusor_range = range
var repulsor_push = push
var repulsor = self;
with(obj_enemy) {
	if (distance_to_object(repulsor) < replusor_range) 
	{
		move_towards_point(repulsor.x, repulsor.y, -repulsor_push);
		//x -= repulsor_push ; 
		//y -= repulsor_push ; 
	}
}

sprite_index = 0;
alarm[0] = push_timer;