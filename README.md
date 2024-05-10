# spatialPhotoTool

The goal of this tool is to combine the logic from my [spatialPhotoCombiner](https://github.com/zenwheel/spatialPhotoCombiner), [mposplit](https://github.com/zenwheel/mposplit) and [sbssplit](https://github.com/zenwheel/sbssplit) tools into one command which can convert photos from both the [Fujifilm FinePix Real 3D W3](https://www.dpreview.com/products/fujifilm/compacts/fujifilm_w3) and the [Kandao QooCam EGO](https://www.kandaovr.com/qoocam-ego) into spatial photos compatible with the Apple Vision Pro and preserves proper metadata for Apple Photos.

## Usage

```
USAGE: spatialPhotoTool [<files> ...] [--hfov <hfov>]

ARGUMENTS:
  <files>

OPTIONS:
  --hfov <hfov>           Horizontal field-of-view (in degrees).
  -h, --help              Show help information.
```

* Fujifilm FinePix Real 3D W3 -- use an `--hfov` of `48`
* Kandao QooCam EGO -- use an `--hfov` of `66`
* if no `--hfov` is specified, it will default to `48` for `.MPO` files and `66` for `.jpg`


# spatialVideoTool

Kandao provides [QooCam EGO spatial video and photo converter](https://www.kandaovr.com/support/detail?item=consumer&id=vLmegvkJ74wX) which works for videos recorded on the QooCam EGO, but the photos it creates do not work on Apple Vision Pro.  Videos from this camera and from this tool also do not contain any metadata about the camera.

To convert videos recorded on the Fujifilm FinePix Real 3D W3, you must first convert the dual-video `.AVI` file to a known format (side-by-side, `ffmpeg` command below) and then you can convert that with the [spatial](https://blog.mikeswanson.com/spatial) tool from Mike Swanson.

```
ffmpeg -noautorotate -y -i file.AVI -filter_complex "[0:0][0:2] hstack=inputs=2 [out]" -vcodec libx264 -preset slow -crf 18 -x264opts frame-packing=3 -map "[out]" -map 0:1 side-by-side.mp4
```

I've included the scripts I use to convert both videos from the Fujifilm FinePix Real 3D and the QooCam EGO in the `spatialVideoTool` directory -- `convert_avi.sh` will convert the `.AVI` files produced with the Fujifilm camera and `convert_qoocam.sh` will convert the `.mp4` files produced with the QooCam EGO.

Adjusting the `HFOV` and `CDIST` values in the scripts could probably generalize them to other multi-video `.AVI` files like the Fujifilm Real 3D cameras produce or other side-by-side videos like the QooCam produces.

These scripts preserve and/or generate proper metadata so Apple Photos shows the expected camera information.

## References

* https://www.finnvoorhees.com/words/reading-and-writing-spatial-photos-with-image-io
* https://github.com/studiolanes/vision-utils
* https://leimao.github.io/blog/Camera-Intrinsics-Extrinsics/
* https://blog.mikeswanson.com/spatial
* https://github.com/zenwheel/spatialPhotoCombiner
* https://github.com/zenwheel/mposplit
* https://github.com/zenwheel/sbssplit