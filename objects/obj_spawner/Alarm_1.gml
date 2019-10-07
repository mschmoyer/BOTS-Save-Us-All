/// @description Spawn the minerals

if (instance_number(obj_mineral) < mineral_max_on_screen) {

	// Create a mineral - anywhere but the border tiles
	inst = instance_create_layer(spawn_margin+random(room_width-(spawn_margin*2)),
								spawn_margin+random(room_height-(spawn_margin*2)),
								"PhysicalObjectsLayer",
								obj_mineral);
	
	// Restart spawn timer.
	alarm[1] = mineral_spawn;

	minerals_spawned++;
	
	// On the first mineral spawned, offer a tip. 
	if( minerals_spawned == 1 ) {
		// Show the mineral tip.
		instance_create_layer(inst.x+40,inst.y-188,"InterfaceLayer",obj_pickup_mineral_tip);
	}

}