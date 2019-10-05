/// @description Insert description here
// You can write your code in this editor

if (obj_score.trees_planted >= 0)
{
	instance_create_layer(random(room_width),random(room_height),"EnemyLayer",obj_enemy);
	alarm[0] = spawnrate;
	alarm[1] = lifespan;
}
