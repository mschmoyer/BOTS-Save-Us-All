/// @description Move the character

if (obj_score.end_game_triggered == true && !global.dialogActive)
{
	speed = 5;
	move_towards_point(obj_boss.x, obj_boss.y, speed);
}