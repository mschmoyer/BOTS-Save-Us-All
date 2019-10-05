/// @description Insert description here

var cx = camera_get_view_x(view_camera[0]);
var cy = camera_get_view_y(view_camera[0]);
var cw = camera_get_view_width(view_camera[0]);

draw_set_font(fnt_score);
draw_set_colour(c_white);
draw_text(cx+cw/2,cy+25,"O2 gauge:"+string(trees_planted / trees_left));
draw_text(cx+cw/2,cy+50,"Metal:"+string(metal));