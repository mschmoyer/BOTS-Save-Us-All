/// @description Insert description here
// You can write your code in this editor

chomp_frame = (chomp_frame==1 ? 0 : 1);
image_index = chomp_frame;
alarm[0] = chomp_speed;

// Sometimes, play chomp sound
if( !hasBittenSomething ) {
	audio_play_sound(snd_eat_tree,20,false);	
	hasBittenSomething = true;
}