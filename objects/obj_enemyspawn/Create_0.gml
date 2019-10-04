/// @description Insert description here
// You can write your code in this editor

image_xscale = 0.1;
image_yscale = 0.1;
hp = 1;
spd = 15;

if( random_range(1,10) >= 7 ) {
	sprite_index = spr_mike;
	hp = 9;
	spd = 2.5;
} else {
	sprite_index = spr_enemy;
	hp = 1;
	spd = 1.5;
}