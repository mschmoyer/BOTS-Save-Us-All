/// @description Insert description here
// You can write your code in this editor

if (instance_exists(obj_tree)) {

	tree_target = instance_nearest(x,y,obj_tree);
	move_towards_point(tree_target.x, tree_target.y,speed);

}

