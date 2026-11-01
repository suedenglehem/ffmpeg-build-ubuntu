# ffmpeg-build-ubuntu

One-shot build script for the latest FFmpeg release on Ubuntu 24.04 (noble),
with the full codec/library set of `jrottenberg/ffmpeg:9.0-nvidia2404` plus
extras:

- **NVIDIA**: CUDA 13, NVENC, NVDEC/cuvid, `libnpp` (nvcc target auto-detected
  from `nvidia-smi --query-gpu=compute_cap`)
- **Intel QSV / VAAPI**: oneVPL (`libvpl`), `libva` ≥ 2.22 and the
  `intel/media-driver` (iHD) built from source — Intel's apt repo is
  discontinued. Skipped automatically on hosts without an Intel iGPU.
- **Codecs**: x264, x265, SVT-AV1, AOM AV1, dav1d, libvpx, kvazaar, vvenc
  (VVC/H.266), xvid, mp3lame, **fdk-aac**, opencore-amr, twolame, shine, gsm,
  opus, vorbis, theora, speex
- **Subtitles/text**: libass, freetype, fontconfig, fribidi, harfbuzz, aribb24
- **Containers/misc**: bluray, srt, rist, ssh, zmq, curl, openssl, openjpeg,
  webp, jxl, zbar, zvbi, soxr, rubberband, vidstab, zimg, codec2, modplug,
  openmpt, mysofa, v4l2, xml2
- **Quality metrics**: libvmaf (VMAF); SSIM/PSNR are built into FFmpeg
- **ASR**: whisper.cpp (`--enable-whisper`, FFmpeg ≥ 9)

Built `--enable-gpl --enable-version3 --enable-nonfree --enable-shared
--enable-small`, installed to `/usr/local` (→ `/usr/local/bin/ffmpeg`).

## Usage

```sh
SUDO_PASS=yourpassword bash build-ffmpeg.sh          # non-interactive
bash build-ffmpeg.sh                                 # interactive sudo
FFBUILD_SRC=/dd2/andrei/ffmpeg bash build-ffmpeg.sh  # source tree location
```

- Sources are fetched into `$FFBUILD_SRC` (default `/dd2/andrei/ffmpeg`).
- Parallelism: 24 jobs (`JOBS=` in the script).
- Idempotent: pkg-config gates skip libraries already installed; re-run to
  pick up the latest tags.
- Requires CUDA at `/usr/local/cuda-13.0` (override with `CUDA=`); QSV and
  NVENC sections self-gate when the hardware/toolchain is absent.

## Notes

- `xvid` is fetched from downloads.xvid.com; the build skips it with a warning
  if the site is unreachable.
- media-driver is compiled through `-Wno-error` compiler wrappers: bslib
  FORCE-sets `-Werror` deep in its flag lists, and Ubuntu's gcc hardening
  specs add `-Werror=` defaults; the wrapper appends `-Wno-error` at the very
  end, where it wins.
