/// @description Insert description here
// You can write your code in this editor

x=clamp(x, 0, room_width);
y=clamp(y, 0, room_height);

if (instance_exists(obj_tree)) {

	tree_target = instance_nearest(x,y,obj_tree);
	
	if( !tree_target.attacked ) {
		move_towards_point(tree_target.x-5, tree_target.y-5,speed);
	}

	if( distance_to_object(tree_target) < 32 ) {
		// start chomping!
		image_index = chomp_frame;
		if( alarm[0] < 0 ) alarm[0] = chomp_speed;
		
		if( !global.attackTipDone && !global.attackTipStarted ) {
			
			// Start the fighting tip. 
			global.attackTipStarted = true;
			instance_create_depth(0,0,0,obj_dialog_fight);	
		}
		
	}
}

if (being_repulsed) {
	image_index = 2;
	image_alpha -= 0.01;
	if (image_alpha <= 0) instance_destroy();
}
