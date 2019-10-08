
randomize();

global.introductionDone = false;
global.attackTipDone = false;
global.attackTipStarted = false;
global.current_song = 1;
// Music

audio_stop_all();
audio_play_sound(music_stage1, 10, true);