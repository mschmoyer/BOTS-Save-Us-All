/// @description Insert description here
// You can write your code in this editor

scr_DisplayConvoText();

if( finished ) {
	room_goto(rm_ending);
	instance_destroy();
}
