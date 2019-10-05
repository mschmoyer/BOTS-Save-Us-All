/// @description Spawns the enemies

if (obj_score.trees_planted >= 0)
{
	instance_create_layer(random(room_width),random(room_height),"PhysicalObjectsLayer",obj_enemy);
	alarm[0] = spawnrate;
}
