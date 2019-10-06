/// @description Set up vars

// Boss speed
speed = 5;
hp = max(instance_number(obj_planter) + instance_number(obj_robot_builder),1);

audio_play_sound(snd_klaxon,20,false);