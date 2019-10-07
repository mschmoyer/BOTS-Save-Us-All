/// @description Spawn a planter

// Check to make sure there are enough minerals
if (obj_score.minerals >= builder_cost)
{
	instance_create_layer(x,y+128,"PhysicalObjectsLayer",obj_robot_builder);
	obj_score.minerals -= builder_cost;
	
	audio_play_sound(snd_build,20,false);
}	
