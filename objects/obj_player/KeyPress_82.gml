/// @description Spawn repulsor

if (obj_score.minerals >= global.repulsorCost)
{
	instance_create_layer(x,y,"PhysicalObjectsLayer",obj_repulsor_bot);
	obj_score.minerals -= global.repulsorCost;
	
	audio_play_sound(snd_build,20,false);
}
else 
{
	// TODO: Not enough money!	
}

