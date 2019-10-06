/// @description Blow up when hits boss

obj_boss.hp--;

instance_destroy()
audio_play_sound(snd_explostion, 10, false);

