/// @description Insert description here
// You can write your code in this editor

if (keyboard_check(vk_right) || keyboard_check(ord("D"))) {
	x = x + velocity;
	direction = FACING_DIRECTION.dir_right;
}
if (keyboard_check(vk_left)  || keyboard_check(ord("A"))) {
	x = x - velocity;
	direction = FACING_DIRECTION.dir_left;
}

if (keyboard_check(vk_up))   || keyboard_check(ord("W")) {
	y = y - velocity;
	direction = FACING_DIRECTION.dir_up;
}
if (keyboard_check(vk_down)) || keyboard_check(ord("S")) {
	y = y + velocity;
	direction = FACING_DIRECTION.dir_down;
}


// Being knocked away by bad guy.
if( instance_exists(obj_boss) ) {
	if obj_score.end_game_triggered && point_distance(x, y, obj_boss.x, obj_boss.y) < 100
	   move_towards_point(obj_boss.x, obj_boss.y, -200);
	else speed = 0;
}

// Stop from moving off screen
x=clamp(x, 0, room_width);
y=clamp(y, 0, room_height);
