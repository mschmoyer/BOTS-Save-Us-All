/// @description Plant tree and die

// Plant a tree
if (!kamikaze) {
	instance_create_layer(x,y,"PhysicalObjectsLayer",obj_tree);
	alarm[1] = tree_planting_rate;
}

// Doesn't die right now
//instance_destroy();
