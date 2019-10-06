/// @description Insert description here
// You can write your code in this editor


draw_sprite(spr_boss,0,x,y);

draw_set_color(c_red);
draw_rectangle(x-256,y-100,x+256,y-90,false);


x2 = ((hp / max_hp) * 512) - 256;


draw_set_color(c_lime);
draw_rectangle(x-256,y-100,x2,y-90,false);