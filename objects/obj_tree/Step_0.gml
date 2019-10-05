/// @description Tree growth

// Ages the tree
if (tree_stage < 3) tree_growth = tree_growth + 1;

if (tree_growth >= tree_nextlevel) {
	// Grow to next stage. 
	if (tree_stage < 3) {
		tree_nextlevel = random_range(min_growth_val,max_growth_val);
		tree_stage = tree_stage + 1;
		tree_growth = 0;
		image_index = tree_stage;
		obj_score.trees_planted++;
		obj_score.trees_left--;
	}
}

// Max size trees drop seedlings
if (tree_stage == 3 && !on_planting_cooldown)
{
	alarm[1] = seedling_timer;
	on_planting_cooldown = true;
}