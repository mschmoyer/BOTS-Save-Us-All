/// @description Runs the end game event

// Spawns boss
instance_create_layer(128+random(room_width-256),128+random(room_height-256),"PhysicalObjectsLayer",obj_boss);

// Alarm for robots to converge on boss