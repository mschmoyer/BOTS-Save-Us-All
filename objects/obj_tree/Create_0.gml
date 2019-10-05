/// @description Insert description here
// You can write your code in this editor

obj_score.trees_left--;
obj_score.trees_planted++;

tree_stage = 0;
tree_growth = 0;
tree_nextlevel = random_range(500,2000);

image_speed = 0;
image_index = tree_stage;