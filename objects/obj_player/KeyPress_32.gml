/// @description Create planter

// Check to make sure there are enough minerals and no dialgoue is active
if (obj_score.minerals >= global.planterCost && 
	!global.dialogActive)
{
	instance_create_layer(x,y+128,"PhysicalObjectsLayer",obj_planter);
	obj_score.minerals -= global.planterCost;
	audio_play_sound(snd_build,20,false);
	
	
	// Destroy ALL mineral tips on screen (should only be 1)
	if ( instance_exists(obj_build_planter_tip) ) {
		obj_build_planter_tip.tip_disappearing = true;
	}
} 
else 
{
	// TODO: Not enough minerals!	
}


