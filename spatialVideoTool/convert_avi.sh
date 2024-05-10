#!/bin/sh

FUJI_HFOV=48
FUJI_CDIST=75

AVIFILES=$(ls -1 | grep -E '\.AVI$')
if [ ! -z "$AVIFILES" ]; then	
	for NAME in $AVIFILES; do
		BASENAME=$(echo $NAME | sed 's/\.AVI//')
		echo "Converting $BASENAME to side-by-side..."
		ffmpeg -noautorotate -y -i "$BASENAME.AVI" -filter_complex "[0:0][0:2] hstack=inputs=2 [out]" -vcodec libx264 -preset slow -crf 18 -x264opts frame-packing=3 -map "[out]" -map 0:1 "$BASENAME"_LRF.mp4
		exiftool -overwrite_original -tagsfromfile "$BASENAME.AVI" "$BASENAME"_LRF.mp4
	
		echo "Converting $BASENAME to spatial MV-HEVC..."
		spatial make -i "$BASENAME"_LRF.mp4 -y -f sbs -b 15M --use-gpu --cdist $FUJI_CDIST --hfov $FUJI_HFOV --hadjust 0 -o "$BASENAME"_spatial.mov
		exiftool -api quicktimeutc=1 -overwrite_original -tagsfromfile "$BASENAME.AVI"  "$BASENAME"_spatial.mov
	done
fi