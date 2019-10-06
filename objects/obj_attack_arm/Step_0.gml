
/// @description Insert description here
// You can write your code in this editor

if( attacking ) {
	
	image_angle = direction;
	
	// At end of swing, start pulling it back in. 
	if (swing_dist >= swing_max_dist) {
		swing_dir = 1;
	}

	// As weapon is pulled all the way in, finish swing. 
	if (swing_dist <= 0 && swing_dir > 0) {
		attacking = false;
		visible = false;
		cooldown = cooldown_max;
		swing_dist = 0;
		swing_dir = 0;
	}

	// If moving out, else in. 
	if( swing_dir > 0 ) {
		offset -= swing_speed;
		swing_dist -= swing_speed;
	} else {
		offset += swing_speed;
		swing_dist += swing_speed;
	}
	
	switch(direction) {
		case FACING_DIRECTION.dir_down:
			y = obj_player.y + offset;
			break;
		case FACING_DIRECTION.dir_left:
			x = obj_player.x - offset;
			break;
		case FACING_DIRECTION.dir_right:
			x = obj_player.x + offset;
			break;
		case FACING_DIRECTION.dir_up:
			y = obj_player.y - offset;
			break;
	}
	
}

// Cause a cooldown on swings. 
if (cooldown > 0) cooldown--;