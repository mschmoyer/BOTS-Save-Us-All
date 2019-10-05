/// @description Spawn the minerals

instance_create_layer(random(room_width),random(room_height),"PhysicalObjectsLayer",obj_mineral);
	
alarm[1] = mineral_spawn;