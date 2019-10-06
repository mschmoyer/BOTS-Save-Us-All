/// @description Check for events

// Transition music

if( trees_planted > 6 && !enemySpawnerCreated ) {
	// Introduce baddies. 
	instance_create_layer(0,0,"EffectsLayer",obj_enemy_spawner);
	enemySpawnerCreated = true;
}

if( trees_planted > (TREES_TO_WIN/4) && current_song < 2 ) {
	
	// Play transition to stage 2
	audio_stop_sound(music_stage1);
	audio_play_sound(music_stage1_stage2_transition, 10, false);	
	current_song = 2;
	alarm[0] = 360;
}

// Start end game event 100%!
if (trees_planted >= TREES_TO_WIN && !end_game_triggered)
//if (trees_planted >= 1 && !end_game_triggered)
{
	end_game_triggered = true;
	instance_create_depth(0,0,0,obj_end_game_start);
	//room_goto(rm_title);
	
	alarm[1] = 5*60;
}