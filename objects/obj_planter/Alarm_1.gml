/// @description Plant tree and die
// You can write your code in this editor

// Plant a tree
instance_create_layer(x,y,"Instances",obj_tree);

// Sometimes break into more planters
if( random_range(1,20) > 15 ) {
	instance_create_layer(x,y,"Instances",obj_planter);
	instance_create_layer(x,y,"Instances",obj_planter);
	instance_create_layer(x,y,"Instances",obj_planter);
}

instance_destroy();
