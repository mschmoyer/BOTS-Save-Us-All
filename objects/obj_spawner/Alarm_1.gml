/// @description Spawns resource

instance_create_layer(random(room_width),random(room_height),"PhysicalObjectsLayer",obj_metal);
alarm[1] = resource_spawn_rate