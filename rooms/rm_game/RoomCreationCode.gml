
randomize();

global.introductionDone = false;
global.attackTipDone = false;
global.attackTipStarted = false;
global.current_song = 1;

// Resource costs
global.planterCost = 10; // 10
global.builderCost = 35; // 40
global.repulsorCost = 5; // 5


// Initial game world Music
audio_stop_all();
audio_play_sound(music_stage1, 10, true);