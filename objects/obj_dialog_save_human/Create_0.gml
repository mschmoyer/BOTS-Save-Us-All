/// @description Insert description here
// You can write your code in this editor

scr_InitializeDialog1();

if (!active) {
	active = true;
	convoIndex = 0;
	convo_robots_save_us();
	scr_DisplayConvoText();
}