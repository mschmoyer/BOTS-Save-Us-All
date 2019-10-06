/// @description Moves towards player

// Move to player
//if( !global.dialogActive) {
	move_towards_point(obj_player.x, obj_player.y, speed);
//} else {
//	speed = 0;	
//}

x=clamp(x, 0, room_width);
y=clamp(y, 0, room_height);

if( hp <= 0 ) {

	// Boss defeated! Win the game!
	instance_destroy();
	instance_destroy(obj_enemy); // destroy all enemies. 

}