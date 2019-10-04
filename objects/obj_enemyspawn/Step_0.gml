/// @description Insert description here
// You can write your code in this editor

image_xscale = min(image_xscale+0.02,1);
image_yscale = min(image_yscale+0.02,1);

if (image_xscale == 1) {

	mySprite = sprite_index;
	myHp = hp;
	instance_change(obj_enemy,true);
	
	sprite_index = mySprite;
	hp = myHp;
	//with (inst) sprite_index = other.sprite_index
}