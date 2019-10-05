/// @description Sets timers for object spawning

// For spawning tree eaters
spawnrate = random_range(1000,3000);
alarm[0] = 1;

// For spawning resources
resource_spawn_rate = 200;
alarm[1] = resource_spawn_rate;