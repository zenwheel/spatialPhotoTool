#!/bin/sh

QOOCAM_HFOV=66
QOOCAM_CDIST=65

QCFILES=$(ls -1 | grep -E '[[:digit:]]{4}_[[:digit:]]{8}_[[:digit:]]{6}_[[:digit:]]{2}\.mp4$')
if [ ! -z "$QCFILES" ]; then
	for NAME in $QCFILES; do
		BASENAME=$(echo $NAME | sed 's/\.mp4//')
		echo "Converting $BASENAME..."
		spatial make -i "$BASENAME.mp4" -y -f sbs -b 30M --use-gpu --cdist $QOOCAM_CDIST --hfov $QOOCAM_HFOV --hadjust 0 -o "$BASENAME.mov"
		touch -r "$BASENAME.mp4" "$BASENAME.mov"
		exiftool -api quicktimeutc=1 -overwrite_original -Make="Kandao" -Model="QooCam EGO" "-CreateDate<FileModifyDate" "-ModifyDate<FileModifyDate" "$BASENAME.mov"
	done
fi