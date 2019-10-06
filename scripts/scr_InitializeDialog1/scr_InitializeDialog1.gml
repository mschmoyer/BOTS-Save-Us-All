
global.dialogActive = true;
global.dialogInstance = self;
finished = false;

padding = 50;

width = room_width - (padding * 2);
height = 200;
xOrigin = (room_width/2)-(width/2); // center
yOrigin = room_height-height-padding; // bottom

bordersize = 20;
innerBoxWidth = width - bordersize;
innerBoxHeight = height - bordersize;
innerBox_xOrigin = xOrigin + (bordersize / 2);
innerBox_yOrigin = yOrigin + (bordersize / 2);

avatarScale = 1;
avatar_xOrigin = innerBox_xOrigin + 15;
avatar_yOrigin = innerBox_yOrigin + 20;

text_xOrigin = avatar_xOrigin + 150;
text_yOrigin = avatar_yOrigin + 25;

for (i=0;i<100;i++) {
	dialog[i, 0] = -1;
	dialog[i, 1] = "";
}

active = false;

convoDialogCount = 0;
convoIndex = 0;
spriteToDisplay = -1;
stringToDisplay = "";
spriteImageIndexToDisplay = 0;
currCharIndex = 1;