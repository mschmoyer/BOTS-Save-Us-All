
if( currCharIndex < string_length(dialog[convoIndex,1]) + 1) {
	
	spriteToDisplay = dialog[convoIndex, 0];
	spriteImageIndexToDisplay = dialog[convoIndex, 2];
	stringToDisplay += string_char_at(dialog[convoIndex,1], currCharIndex++);

} else {

	if (keyboard_check_pressed(vk_space)) {
		convoIndex++;
		stringToDisplay = "";
		currCharIndex = 1;
		
		if (convoIndex == convoDialogCount) {
			finished = true;
			global.dialogActive = false;
			//active = false;
		}
	}

}