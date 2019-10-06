/// @description Insert description here
// You can write your code in this editor

// Cause a "fade-in"
image_alpha = 0;
tip_appearing = true;

// For a future "fade-out"
tip_disappearing = false;

hover_offset = 0;
hover_delta = 1;


// Now destroy the previous tip. 
instance_destroy(obj_pickup_mineral_tip);