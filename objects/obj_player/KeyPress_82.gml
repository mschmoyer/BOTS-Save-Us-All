/// @description Spawn repulsor

if (obj_score.minerals >= 5)
{
	instance_create_layer(x,y,"PhysicalObjectsLayer",obj_repulsor_bot);
	obj_score.minerals -= 5;
	
	audio_play_sound(snd_build,20,false);
}	

