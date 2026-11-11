# Review video fixture

`ReviewVideo.mov` is an original synthetic 16×16 black H.264 movie, two frames at 2 fps, without audio. It exercises local AVFoundation container loading without requiring a camera or network. No external media or copyrighted source material is used.

Generation (FFmpeg is needed only to regenerate the fixture, not to run tests):

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=16x16:r=2 -frames:v 2 -c:v libx264 -pix_fmt yuv420p -an -map_metadata -1 -fflags +bitexact -flags:v +bitexact ReviewVideo.mov
```
