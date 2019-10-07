/// @description Spawn Tree Eaters
// You can write your code in this editor

if (obj_score.trees_planted >= 0)
{
	
	enum Side{
	    Top, Bottom, Left, Right, _count
	}

	var side = irandom(Side._count-1);
	var spawnX = (side < 2) * irandom(room_width) + (side == Side.Right) * room_width;
	var spawnY = (side > 1) * irandom(room_height) + (side == Side.Bottom) * room_height;
	
	instance_create_layer(spawnX, spawnY,"PhysicalObjectsLayer", obj_enemy);
	
	// This spawns anywhere.
	//instance_create_layer(random(room_width), random(room_height),"PhysicalObjectsLayer", obj_enemy);
	
	alarm[0] = spawnrate;
}

