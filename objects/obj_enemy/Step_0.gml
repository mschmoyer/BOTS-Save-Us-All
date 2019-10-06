/// @description Insert description here
// You can write your code in this editor

if (instance_exists(obj_tree)) {

	tree_target = instance_nearest(x,y,obj_tree);
	move_towards_point(tree_target.x-5, tree_target.y-5,speed);

}

if (being_repulsed) {
	image_alpha -= 0.01;
	if (image_alpha <= 0) instance_destroy();
}
