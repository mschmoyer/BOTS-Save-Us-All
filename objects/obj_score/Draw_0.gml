/// @description Insert description here

var cx = camera_get_view_x(view_camera[0]);
var cy = camera_get_view_y(view_camera[0]);
var cw = camera_get_view_width(view_camera[0]);


// This code will color the o2 level based on completeness.
oxygen_level = min((trees_planted / trees_left),1) * 100;
oxygen_stage = round(oxygen_level / 25);
switch(oxygen_stage) {
	case 0:
		draw_set_colour(c_red);
	case 1:
		draw_set_colour(c_orange);
	case 2:
		draw_set_colour(c_yellow);
	case 3:
		draw_set_colour(c_lime);
	case 4:
		draw_set_colour(c_aqua);
	default:
		draw_set_colour(c_white);
}
draw_set_font(fnt_score);
draw_text(cx+cw/2+500,
		  cy+25,
		  "o2 Level: " + string(oxygen_level) + "%");
		  
draw_set_font(fnt_score);
draw_set_colour(c_white);  
draw_text(cx+cw/2-1000,
		  cy+25,
		  "Scrap Metal: " + string(minerals));