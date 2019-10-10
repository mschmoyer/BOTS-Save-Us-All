/// @description Insert description here

var cx = camera_get_view_x(view_camera[0]);
var cy = camera_get_view_y(view_camera[0]);
var cw = camera_get_view_width(view_camera[0]);


// This code will color the o2 level based on completeness.
oxygen_level = min((trees_planted / TREES_TO_WIN),1) * 100;
oxygen_stage = round(oxygen_level / 25);

// Draw the o2 sensor
draw_set_font(fnt_score);
draw_text(cx+cw/2+700,
		  cy+25,
		  "o2 Level: " + string(round(oxygen_level)) + "%");
		  
// Draw the mineral counter
draw_set_font(fnt_score);
draw_set_colour(c_white);  
draw_text(cx+cw/2-1000,
		  cy+25,
		  "Minerals: " + string(minerals));
		  
// Draw the instructions and available commands
draw_set_font(fnt_score);
draw_set_color(c_white);
draw_text(cx+cw/2-630,cy+25,"SPACE=Planter ["+string(global.planterCost)+"]    Q=Builder ["+string(global.builderCost)+"]    R=Repulsor ["+string(global.repulsorCost)+"]");