/// @description Insert description here
// You can write your code in this editor

if (tree_stage < 3) tree_growth = tree_growth + 1;

if (tree_growth >= tree_nextlevel) {
	// Grow to next stage. 
	if (tree_stage < 3) {
		tree_nextlevel = random_range(3000,9000);
		tree_stage = tree_stage + 1;
		tree_growth = 0;
		image_index = tree_stage;
	}
}