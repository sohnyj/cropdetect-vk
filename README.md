# cropdetect-vk

`cropdetect_vulkan`, a Vulkan port of FFmpeg's `cropdetect` filter, as a patch
for FFmpeg, and an mpv script that uses it to crop black bars during playback.

## cropdetect_vulkan

Auto-detect the crop size on Vulkan frames.

It calculates the necessary cropping parameters and prints the recommended
parameters via the logging system and the frame metadata. The detected
dimensions correspond to the non-black area of the input video. The frames
are passed on unchanged.

The metadata keys (`lavfi.cropdetect.x1`, `x2`, `y1`, `y2`, `w`, `h`, `x`,
`y`, `limit`) and the log line are those of `cropdetect`, and so are the
values: for the same frames both filters report the same numbers.

### Differences from cropdetect

- The frames stay on the GPU. A compute shader sums the luma plane per row
  and per column, and only these sums are read back.
- Only the `black` mode is implemented. The options `mode`, `mv_threshold`,
  `low` and `high` do not exist.
- The timeline option `enable` is not supported.

### Supported input

- Vulkan hardware frames only. Frames of a Vulkan decoder are read in place;
  other frames have to be uploaded first, with `hwupload` in FFmpeg or
  `format=fmt=vulkan` in mpv.
- Planar and semi-planar YUV formats with 8 to 16 bits, such as `nv12`,
  `p010`, `p012`, `p016` and `yuv420p10`. Only the luma plane is examined.
- RGB, XYZ, packed and floating-point formats are rejected.

As with the other Vulkan filters, a hardware device has to be initialized and
passed to the filter graph; see "Vulkan Video Filters" in the FFmpeg filters
documentation.

It has been tested on Windows with an NVIDIA GPU.

### Options

It accepts the following parameters:

- `limit`

  Set higher black value threshold, which can be optionally specified from
  nothing (0) to everything (255 for 8-bit based formats). An intensity value
  greater to the set value is considered non-black. It defaults to 24. You can
  also specify a value between 0.0 and 1.0 which will be scaled depending on
  the bitdepth of the pixel format.

- `round`

  The value which the width/height should be divisible by. It defaults to 16.
  The offset is automatically adjusted to center the video. Use 2 to get only
  even dimensions (needed for 4:2:2 video). 16 is best when encoding to most
  video codecs.

- `skip`

  Set the number of initial frames for which evaluation is skipped. Default
  is 2. Range is 0 to INT_MAX.

- `reset_count`, `reset`

  Set the counter that determines after how many frames the filter will reset
  the previously detected largest video area and start over to detect the
  current optimal crop area. Default value is 0.

  This can be useful when channel logos distort the video area. 0 indicates
  'never reset', and returns the largest area encountered during playback.

- `max_outliers`

  Set the number of non-black lines that may be passed over while searching
  from an edge towards the picture. Default value is 0, which stops at the
  first non-black line.

### Examples

- Find the video area surrounded by black borders, decoding with Vulkan:

  ```
  ffmpeg -init_hw_device vulkan -hwaccel vulkan -hwaccel_output_format vulkan -i file.mkv -vf cropdetect_vulkan,metadata=mode=print -f null -
  ```

- The same for frames decoded in software:

  ```
  ffmpeg -init_hw_device vulkan=vk -filter_hw_device vk -i file.mkv -vf hwupload,cropdetect_vulkan,metadata=mode=print -f null -
  ```

- Print the detected area in mpv:

  ```
  mpv --vo=gpu-next --gpu-api=vulkan --hwdec=vulkan --vf=lavfi=[cropdetect_vulkan] -v file.mkv
  ```

### Commands

This filter supports the following commands:

- `limit`

  The command accepts the same syntax of the corresponding option. If the
  specified expression is not valid, it is kept at its current value.

## Building

The patch is made against FFmpeg master. Apply it with the script next to it,
which keeps working when FFmpeg changes the lines around the ones that
register the filter:

```
cmake -DSOURCE_DIR=<ffmpeg> -P patch/ffmpeg-add-cropdetect_vulkan-filter.cmake
```

Then configure FFmpeg with `--enable-gpl` and `--enable-vulkan`, and have a
SPIR-V compiler (`glslc`, `glslang` or `glslangValidator`) available at build
time.

## mpv script

`script/toggle_autocrop.lua` inserts `cropdetect_vulkan` and applies the
detected area through `video-crop`. It needs `--gpu-api=vulkan`; with
`--hwdec=vulkan` the frames are read in place, with other decoders they are
uploaded first.

```
KEY script-message toggle_autocrop
```

`script/toggle_autocrop.conf` is an example for `script-opts`.
