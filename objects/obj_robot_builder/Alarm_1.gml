/// @description Spawn a planter object

if( robotSupply > 0 )
{
	instance_create_layer(x,y,"PhysicalObjectsLayer",obj_planter);
	alarm[1] = buildRate;
}
else {
	// I have no resources to build a new robot!	
	
	// TODO: Maybe I can find nearby minerals to increase supply?
}