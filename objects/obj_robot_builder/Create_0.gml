/// @description Sets up vars for the builder
// Timer for movement
alarm[0] = 60;

// Timer to spawn
buildRate = 400;
alarm[1] = buildRate;

// Timer to die
alarm[2] = 600;

// Unit speed
speed = 2;

// Unit cost
cost = 6;

// Emotional reaction to human in distress
kamikaze = false;

// Initially, can build 4 robots. 
robotSupply = 4;