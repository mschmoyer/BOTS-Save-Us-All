/// @description Hit the enemy!
// You can write your code in this editor



var replusor_range = 64;
var repulsor_push = 10;
var repulsor = self;
with(obj_enemy) {
	if (distance_to_object(repulsor) < replusor_range) 
	{
		move_towards_point(repulsor.x, repulsor.y, -repulsor_push);
		being_repulsed = true;
		//x -= repulsor_push ; 
		//y -= repulsor_push ; 
	}
}