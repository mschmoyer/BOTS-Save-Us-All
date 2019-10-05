/// @description Insert description here
// You can write your code in this editor
influence_distance = 20;
influenced_index = 1;

// If within range, influence blob
/*
if (distance_to_object(obj_player) <= influence_distance && !influenced)
{
	image_index = influenced_index;
	influenced = true;
	obj_score.thescore++;
	
	// Find the target
	//index_of_target = instance_find(obj_blob, irandom(instance_number(obj_blob) - 1));
	index_of_target = instance_nearest(x, y, obj_blob);
}
*/