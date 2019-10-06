/// @description Set up vars

// Boss speed
speed = 5;

max_hp = max(instance_number(obj_planter) + instance_number(obj_robot_builder),1);
hp = max_hp;

audio_play_sound(snd_klaxon,20,false);