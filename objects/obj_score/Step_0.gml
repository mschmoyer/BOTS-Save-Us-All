/// @description Insert description here
// You can write your code in this editor


if( trees_planted > (TREES_TO_WIN/4) && current_song < 2 ) {
	
	// Play transition to stage 2
	audio_stop_sound(music_stage1);
	audio_play_sound(music_stage1_stage2_transition, 10, false);	
	current_song = 2;
	alarm[0] = 360;
}

if (trees_planted >= TREES_TO_WIN)
{
	// You win!!
	room_goto(rm_title);
	//game_end();
}