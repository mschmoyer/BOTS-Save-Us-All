/// @description When at max growth, drops a seedling


// Only spawn new trees if the game is still on. 
if (obj_score.trees_planted < obj_score.TREES_TO_WIN) {

	//instance_create_layer(x + irandom_range(-OFFSET, OFFSET),
	//					  y + irandom_range(-OFFSET, OFFSET),
	//					  "TreeLayer",
	//					  obj_tree);

	// For comparing distances to other trees
	var spawning_tree = self

	x_offset = 0;
	y_offset = 0;

	// Find a valid placement
	bad_placement = true;

	while (bad_placement)
	{
		bad_placement = false;
		// Find the offsets
		x_offset = ( irandom_range(0,1) ? irandom_range(-OFFSET_MIN, -OFFSET_MAX) : irandom_range(OFFSET_MIN, OFFSET_MAX))
		y_offset = ( irandom_range(0,1) ? irandom_range(-OFFSET_MIN, -OFFSET_MAX) : irandom_range(OFFSET_MIN, OFFSET_MAX))

		// Make sure the tree is not too close
		with(obj_tree)
		{
			// If it is too close, find another location
			
			if (distance_to_object(spawning_tree) < min_distance_to_other)
			{
				bad_placement = true;
				break;
			}
		}	
	}
	// Create the tree
	instance_create_layer(x + x_offset,
						  y + y_offset,
						  "TreeLayer",
						  obj_tree);
}

alarm[1] = seedling_timer;
on_planting_cooldown = false;