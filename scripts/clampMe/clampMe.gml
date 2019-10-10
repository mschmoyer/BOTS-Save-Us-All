
// Prevent this object from moving outside the room boundaries

margin = argument0;

x=clamp(x, margin, room_width-(margin*2));
y=clamp(y, margin, room_height-(margin*2));