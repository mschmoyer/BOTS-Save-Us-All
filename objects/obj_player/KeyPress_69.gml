/// @description Attack!
// You can write your code in this editor

if( !obj_attack_arm.attacking && obj_attack_arm.cooldown <= 0 ) {
	obj_attack_arm.x = x;
	obj_attack_arm.y = y;
	obj_attack_arm.visible = true;
	obj_attack_arm.attacking = true;
	obj_attack_arm.direction = direction;
}