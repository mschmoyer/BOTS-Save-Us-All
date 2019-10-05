/// @description When at max growth, drops a seedling


// Only spawn new trees if the game is still on. 
if (obj_score.trees_left > 0) {

	instance_create_layer(x + irandom_range(-OFFSET, OFFSET),
						  y + irandom_range(-OFFSET, OFFSET),
						  "TreeLayer",
						  obj_tree);
}

alarm[1] = seedling_timer;
on_planting_cooldown = false;