/// @description Spawn a planter

// Spawn a robot
if (obj_score.minerals >= 3)
{
	instance_create_layer(x,y+128,"PhysicalObjectsLayer",obj_robot_builder);
	obj_score.minerals -= 3;
	
	audio_play_sound(snd_build,20,false);
}	
