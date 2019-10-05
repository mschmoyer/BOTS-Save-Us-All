/// @description When at max growth, drops a seedling

instance_create_layer(x + irandom_range(-OFFSET, OFFSET),
					  y + irandom_range(-OFFSET, OFFSET),
					  "TreeLayer",
					  obj_tree);

alarm[1] = seedling_timer;
on_planting_cooldown = false;