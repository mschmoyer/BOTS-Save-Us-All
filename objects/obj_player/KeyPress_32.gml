/// @description Create planter
// You can write your code in this editor

// Spawn a robot
if (obj_score.minerals >= 1 && !global.dialogActive)
{
	instance_create_layer(x,y+128,"PhysicalObjectsLayer",obj_planter);
	obj_score.minerals--;
	audio_play_sound(snd_build,20,false);
	
	
	// Destroy ALL mineral tips on screen (should only be 1)
	if ( instance_exists(obj_build_planter_tip) ) {
		obj_build_planter_tip.tip_disappearing = true;
	}

}


