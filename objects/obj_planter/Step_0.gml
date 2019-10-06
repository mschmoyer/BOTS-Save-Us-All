/// @description Move the character

if (obj_score.good_robots_rebel == true && !global.dialogActive)
{
	speed = 5;
	move_towards_point(obj_boss.x, obj_boss.y, speed);
}