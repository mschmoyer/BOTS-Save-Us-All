/// @description Insert description here
// You can write your code in this editor
influence_distance = 20;
influenced_index = 1;

// If within range, influence blob
if (distance_to_object(obj_player) <= influence_distance && !influenced)
{
	image_index = influenced_index;
	influenced = true;
	obj_score.thescore++;
}