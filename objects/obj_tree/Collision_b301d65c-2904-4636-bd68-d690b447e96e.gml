/// @description Trigger thr countdown until the tree eater eats the tree

if (!attacked && !obj_score.end_game_triggered)
{
	alarm[0] = tree_life;
	attacked = true;
}