/// @description Insert description here
// You can write your code in this editor

draw_sprite(spr_robot_tree_planter,0,x,y);


// The love of robots!
if (obj_end_game_start.good_robots_rebel == true && !global.dialogActive) {
	
	//draw_sprite(spr_love_bubble,0,x+40,y-60);
	
	draw_sprite_part_ext(spr_love_bubble,0,0,0,128,128,x+40,y-260,1,1,c_white,0.8);
}