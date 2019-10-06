/// @description Insert description here
// You can write your code in this editor

if ( tip_disappearing == true && !tip_dead ) {
	image_alpha-=0.05; // fade out. 
	if (image_alpha<=0) {
		alarm[0] = 80;
		tip_dead=true;
	} 
}
if ( tip_appearing == true ) {
	image_alpha+=0.05;
	if image_alpha>=0.8 tip_appearing = false;
}

// Make the tip float up and down
if ( !tip_appearing && !tip_disappearing ) {
	y += hover_delta;
	hover_offset ++;
	if( hover_offset > 40 ) {
		hover_delta = hover_delta * -1;
		hover_offset = 0;
	}
}