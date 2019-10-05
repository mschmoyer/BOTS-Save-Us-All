/// @description Insert description here
// You can write your code in this editor

if (keyboard_check(vk_right) || keyboard_check(ord("D"))) x = x + 4; 
if (keyboard_check(vk_left)  || keyboard_check(ord("A"))) x = x - 4; 

if (keyboard_check(vk_up))   || keyboard_check(ord("W")) y = y - 4; 
if (keyboard_check(vk_down)) || keyboard_check(ord("S")) y = y + 4;

//image_angle = point_direction(x,y,mouse_x,mouse_y);

// Shoot
/*
if (mouse_check_button(mb_left) && cooldown <= 0) {
	instance_create_layer(x, y,"BulletsLayer",obj_bullet);	
	cooldown = 5;
}

if (cooldown > 0) cooldown = cooldown - 1;
/*