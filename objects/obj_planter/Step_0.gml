/// @description Move the character

// Go towards boss
if (obj_score.good_robots_rebel == true && !global.dialogActive)
{
	speed = 5;
	move_towards_point(obj_boss.x, obj_boss.y, speed);
}

x=clamp(x, 0, room_width);
y=clamp(y, 0, room_height);