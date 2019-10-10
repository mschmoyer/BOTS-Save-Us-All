/// @description Move the character

// Go towards boss
if (obj_score.good_robots_rebel == true && !global.dialogActive)
{
	speed = 5;
	if (instance_exists(obj_boss)) move_towards_point(obj_boss.x, obj_boss.y, speed);
}

clampMe(128);