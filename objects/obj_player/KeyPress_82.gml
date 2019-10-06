/// @description Spawn repulsor

if (obj_score.minerals >= 5)
{
	instance_create_layer(x,y+128,"PhysicalObjectsLayer",obj_repulsor_bot);
	obj_score.minerals -= 5;
}	

