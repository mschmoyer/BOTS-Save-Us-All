/// @description Insert description here

// Offset for tree range
OFFSET_MAX= 120;
OFFSET_MIN = 50;

// Crowding distance
min_distance_to_other = 300;

// Range for tree growth timer
min_growth_val = 100;
max_growth_val = 200;

// How long the tree can survive after being attacked
tree_life = 500;

// How long until it spawns a seed
seedling_timer = 800;
on_planting_cooldown = false;

// Affect the score
//obj_score.trees_left--;
obj_score.trees_planted++;

// Start tree life
tree_stage = 0;
tree_growth = 0;
tree_nextlevel = random_range(min_growth_val, max_growth_val);

// Sprites for tree growth
image_speed = 0;
image_index = tree_stage;

// Tree is under attack
attacked = false;

