/// @description Spawn a planter

// Check to make sure there are enough minerals
if (obj_score.minerals >= global.builderCost)
{
	instance_create_layer(x,y+128,"PhysicalObjectsLayer",obj_robot_builder);
	obj_score.minerals -= global.builderCost;
	
	audio_play_sound(snd_build,20,false);
}	
else
{
	// TODO: Not enough money!	
}
