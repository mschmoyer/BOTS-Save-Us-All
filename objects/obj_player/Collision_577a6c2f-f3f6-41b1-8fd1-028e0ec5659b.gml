/// @description Get pushed away from boss



if( soundCooldown <= 0 ) {
	audio_play_sound(snd_robot_hit,20,false);
	soundCooldown = 60;
}
soundCooldown--;