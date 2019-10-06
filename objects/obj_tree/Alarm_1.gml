/// @description When at max growth, drops a seedling


// Only spawn new trees if the game is still on. 
if (obj_score.trees_planted < obj_score.TREES_TO_WIN) {

	//instance_create_layer(x + irandom_range(-OFFSET, OFFSET),
	//					  y + irandom_range(-OFFSET, OFFSET),
	//					  "TreeLayer",
	//					  obj_tree);
						  
	instance_create_layer(x + ( irandom_range(0,1) ? irandom_range(-OFFSET_MIN, -OFFSET_MAX) : irandom_range(OFFSET_MIN, OFFSET_MAX)),
						  y + ( irandom_range(0,1) ? irandom_range(-OFFSET_MIN, -OFFSET_MAX) : irandom_range(OFFSET_MIN, OFFSET_MAX)),
						  "TreeLayer",
						  obj_tree);
}

alarm[1] = seedling_timer;
on_planting_cooldown = false;