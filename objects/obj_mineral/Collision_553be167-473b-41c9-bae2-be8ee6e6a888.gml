/// @description Insert description here

obj_score.minerals++;
instance_destroy();

// Destroy ALL mineral tips on screen (should only be 1)
if ( instance_exists(obj_pickup_mineral_tip) ) {
	obj_pickup_mineral_tip.tip_disappearing = true;
}
