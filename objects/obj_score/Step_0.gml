/// @description Insert description here
// You can write your code in this editor


if( trees_planted > 100 && current_song < 2 ) {
	
// Music
	audio_stop_sound(snd_medium_trees);
	audio_play_sound(snd_background, 10, true);	
	current_song = 2;
}

if (trees_left <= 0)
{
	// You win!!
	room_goto(rm_title);
	//game_end();
}