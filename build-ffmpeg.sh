#!/bin/bash
# build-ffmpeg.sh — latest FFmpeg release with the full library set of
# jrottenberg/ffmpeg:9.0-nvidia2404 (base image of /dd2/andrei/fass/docker),
# plus Intel QSV (oneVPL) + VAAPI, CUDA 13 / NVENC / NVDEC / libnpp.
#
#   install : /usr/local  (ffmpeg, ffprobe, shared libs)
#   sources : $FFBUILD_SRC (default /dd2/andrei/ffmpeg)
#   idempotent: re-run to rebuild with the latest tags
set -euo pipefail

SRC=${FFBUILD_SRC:-/dd2/andrei/ffmpeg}
PREFIX=/usr/local
JOBS=24
CUDA=${CUDA:-/usr/local/cuda-13.0}
NVCC=$CUDA/bin/nvcc
# NVENC kernels target this host's GPU arch (i7 Ada=8.9, tr4 Ampere=8.6)
CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -n | head -1 | tr -d '.')
[ -z "$CC" ] && CC=86
# QSV only where an Intel iGPU exists (i7 yes, tr4 no)
QSV=no
lspci 2>/dev/null | grep -qi 'VGA compatible controller: Intel' && QSV=yes

# sudo helper: set SUDO_PASS in the environment for non-interactive runs,
# otherwise plain interactive sudo is used.
su() {
  if [ -n "${SUDO_PASS:-}" ]; then echo "$SUDO_PASS" | sudo -S -- "$@"
  else sudo "$@"; fi
}
log() { echo; echo "===== $* ====="; }

mkdir -p "$SRC"; cd "$SRC"

# ---------------------------------------------------------------- 1. apt
log "apt: build tools + codec libraries"
su apt-get -qq update
su apt-get install -y --no-install-recommends \
  build-essential git ca-certificates wget curl pkg-config autoconf automake libtool \
  yasm nasm cmake meson ninja-build python3 gettext \
  libx264-dev libx265-dev libaom-dev libdav1d-dev libvpx-dev \
  libmp3lame-dev libfdk-aac-dev libtwolame-dev libshine-dev libgsm1-dev \
  libopencore-amrnb-dev libopencore-amrwb-dev libvo-amrwbenc-dev \
  libopus-dev libvorbis-dev libtheora-dev libspeex-dev \
  libopenjp2-7-dev libwebp-dev libjxl-dev libzbar-dev libzvbi-dev \
  libsoxr-dev librubberband-dev libvidstab-dev libzimg-dev \
  libaribb24-dev libbluray-dev \
  libfreetype-dev libfontconfig1-dev libfribidi-dev libharfbuzz-dev libass-dev \
  libcodec2-dev libmodplug-dev libopenmpt-dev libmysofa-dev \
  librist-dev libssh-dev libzmq3-dev libcurl4-openssl-dev \
  libv4l-dev libxml2-dev libx11-dev libxext-dev xutils-dev \
  libvpl-dev libdrm-dev libva-dev libvdpau-dev libnuma-dev \
  libssl-dev zlib1g-dev libbz2-dev liblzma-dev libpng-dev libjpeg-dev \
  libtiff-dev libopenexr-dev

# Intel media driver (QSV/VAAPI runtime for the iGPU).  Intel's apt repo is
# discontinued (403), so build intel/media-driver from source.  Skipped on
# hosts without an Intel iGPU (QSV=no).
if [ "$QSV" = yes ] && ! ldconfig -p | grep -q 'libmfx-gen'; then
  log "intel-media-driver (QSV/VAAPI runtime)"
  [ -d media-driver/.git ] && git -C media-driver fetch -q --tags \
    || git clone -q --filter=blob:none --recursive https://github.com/intel/media-driver.git
  # 600.x tags are 2018-era; current series is intel-media-2x.y.z
  TAG=$(git -C media-driver tag -l 'intel-media-2*' | sort -V | tail -1)
  git -C media-driver checkout -q "tags/$TAG"
  git -C media-driver submodule update -q --init --recursive
  # gmmlib (bitstream/geometry libs) must sit next to media-driver.
  # media-driver 600.x needs gmmlib master (pGmmGlobalContext API); tags
  # stop at 22.10.x and are too old.
  if [ ! -d gmmlib/Source/GmmLib ]; then
    git clone -q --filter=blob:none https://github.com/intel/gmmlib.git
  fi
  git -C gmmlib checkout -q master && git -C gmmlib pull -q
  # media-driver 26.x finds gmmlib via pkg-config (igdgmm) — install it first
  if ! pkg-config --exists igdgmm; then
    cmake -S gmmlib/Source/GmmLib -B gmmlib/build -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib
    cmake --build gmmlib/build -j"$JOBS"
    su cmake --install gmmlib/build
  fi
  # media-driver 26.x needs libva >= 2.21 (va_dec_vvc.h); noble ships 2.20
  if [ ! -f /usr/local/include/va/va_dec_vvc.h ]; then
    log "libva (VAAPI headers >= 2.21)"
    [ -d libva/.git ] && git -C libva fetch -q --tags \
      || git clone -q --filter=blob:none https://github.com/intel/libva.git
    VTAG=$(git -C libva tag -l '2.*' | sort -V | tail -1)
    git -C libva checkout -q "tags/$VTAG"
    meson setup libva/build libva --prefix=/usr/local --libdir=lib \
          -Ddriverdir=/usr/local/lib/dri
    ninja -C libva/build
    su ninja -C libva/build install
  fi
  # bslib FORCE-sets -Werror deep in its flag lists; wrappers append
  # -Wno-error at the very end of every compile, where it wins.
  mkdir -p bin
  printf '#!/bin/sh\nexec gcc "$@" -Wno-error\n'  > bin/noerr-cc
  printf '#!/bin/sh\nexec g++ "$@" -Wno-error\n'  > bin/noerr-cxx
  chmod +x bin/noerr-cc bin/noerr-cxx
  rm -rf media-driver/build   # compiler change requires fresh cache
  cmake -S media-driver -B media-driver/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_COMPILER="$SRC/bin/noerr-cc" \
        -DCMAKE_CXX_COMPILER="$SRC/bin/noerr-cxx" \
        -DMEDIA_VERSION="2.0.0" -DBUILD_ALONG_WITH_CMRTLIB=1 \
        -DBS_DIR_GMMLIB="$SRC/gmmlib/Source/GmmLib/" \
        -DBS_DIR_COMMON="$SRC/gmmlib/Source/Common/" \
        -DBS_DIR_INC="$SRC/gmmlib/Source/inc/" \
        -DBS_DIR_MEDIA="$SRC/media-driver" \
        -DENABLE_NON_FREE_CODECS=ON -DENABLE_MEDIA_DRIVER=ON \
        -DFull_Open_Source_Support=yes -DENABLE_VCPE=OFF -DENABLE_OCL=OFF
  cmake --build media-driver/build -j"$JOBS"
  su cmake --install media-driver/build
fi

# ------------------------------------------------------- 2. source libs
log "nv-codec-headers (NVENC/NVDEC)"
if [ -d nv-codec-headers/.git ]; then git -C nv-codec-headers pull -q
else git clone -q --depth 1 https://github.com/FFmpeg/nv-codec-headers.git; fi
su make -C nv-codec-headers install PREFIX=$PREFIX

log "SVT-AV1 (AV1 encoder)"
if ! pkg-config --exists svt-av1; then
  [ -d SVT-AV1/.git ] && git -C SVT-AV1 fetch -q --tags \
    || git clone -q --filter=blob:none https://gitlab.com/AOMediaCodec/SVT-AV1.git
  TAG=$(git -C SVT-AV1 tag -l 'v[0-9]*' | sort -V | tail -1)
  git -C SVT-AV1 checkout -q "tags/$TAG"
  cmake -S SVT-AV1 -B SVT-AV1/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build SVT-AV1/build -j"$JOBS"
  su cmake --install SVT-AV1/build
fi

log "libvmaf (VMAF quality metric)"
if ! pkg-config --exists libvmaf; then
  [ -d vmaf/.git ] && git -C vmaf fetch -q --tags \
    || git clone -q --filter=blob:none https://github.com/Netflix/vmaf.git
  TAG=$(git -C vmaf tag -l 'v[0-9]*' | sort -V | tail -1)
  git -C vmaf checkout -q "tags/$TAG"
  rm -rf vmaf/libvmaf/build
  meson setup vmaf/libvmaf vmaf/libvmaf/build --buildtype=release \
        --prefix=$PREFIX --libdir=lib
  ninja -C vmaf/libvmaf/build
  su ninja -C vmaf/libvmaf/build install
fi

log "SRT (secure reliable transport)"
if ! pkg-config --exists srt; then
  [ -d srt/.git ] && git -C srt fetch -q --tags \
    || git clone -q --filter=blob:none https://github.com/Haivision/srt.git
  TAG=$(git -C srt tag -l 'v1.5*' | sort -V | tail -1)
  git -C srt checkout -q "tags/$TAG"
  cmake -S srt -B srt/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib \
        -DENABLE_APPS=OFF -DENABLE_SHARED=ON
  cmake --build srt/build -j"$JOBS"
  su cmake --install srt/build
fi

log "kvazaar (HEVC encoder)"
if ! pkg-config --exists kvazaar; then
  [ -d kvazaar/.git ] && git -C kvazaar pull -q \
    || git clone -q --depth 1 https://github.com/ultravideo/kvazaar.git
  ( cd kvazaar && ./autogen.sh && ./configure --prefix=$PREFIX --libdir=$PREFIX/lib \
      && make -j"$JOBS" && su make install )
fi

log "libvvenc (VVC/H.266 encoder)"
if ! pkg-config --exists libvvenc; then
  [ -d vvenc/.git ] && git -C vvenc fetch -q --tags \
    || git clone -q --filter=blob:none https://github.com/fraunhoferhhi/vvenc.git
  TAG=$(git -C vvenc tag -l 'v[0-9]*' | sort -V | tail -1)
  git -C vvenc checkout -q "tags/$TAG"
  cmake -S vvenc -B vvenc/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build vvenc/build -j"$JOBS"
  su cmake --install vvenc/build
fi

log "xvid (MPEG-4 encoder)"
if [ ! -e /usr/include/xvid.h ]; then
  if wget -q -O xvidcore.tar.gz https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz 2>/dev/null \
     && tar tzf xvidcore.tar.gz >/dev/null 2>&1; then
    tar xzf xvidcore.tar.gz
    XDIR=$(find . -maxdepth 1 -type d -name 'xvidcore*' | head -1)
    ( cd "$XDIR/build/generic" && ./configure --prefix=$PREFIX --libdir=$PREFIX/lib \
        && make -j"$JOBS" && su make install )
  else
    echo "WARN: xvid source unreachable — skipping --enable-libxvid"
  fi
fi

log "whisper.cpp (ffmpeg 9 --enable-whisper)"
if ! pkg-config --exists whisper; then
  [ -d whisper.cpp/.git ] && git -C whisper.cpp fetch -q --tags \
    || git clone -q --filter=blob:none https://github.com/ggml-org/whisper.cpp.git
  TAG=$(git -C whisper.cpp tag -l 'v[0-9]*' | sort -V | tail -1)
  git -C whisper.cpp checkout -q "tags/$TAG"
  cmake -S whisper.cpp -B whisper.cpp/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib \
        -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF
  cmake --build whisper.cpp/build -j"$JOBS"
  su cmake --install whisper.cpp/build
fi

# ---------------------------------------------------------- 3. ffmpeg
log "ffmpeg: latest release"
[ -d ffmpeg/.git ] && git -C ffmpeg fetch -q --tags \
  || git clone -q --filter=blob:none https://github.com/FFmpeg/FFmpeg.git ffmpeg
TAG=$(git -C ffmpeg tag -l 'n[0-9]*' | grep -E '^n[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1)
git -C ffmpeg checkout -q "tags/$TAG"
echo "building ffmpeg $TAG with $JOBS jobs"

log "configure (docker parity + QSV + extras)"
cd "$SRC/ffmpeg"
E=()
pc()  { pkg-config --exists "$1" 2>/dev/null && E+=(--enable-"$2") || true; }
hdr() { [ -e "$1" ] && E+=(--enable-"$2") || true; }
pc libx264 libx264;  pc libx265 libx265;  pc aom libaom
pc svt-av1 libsvtav1; pc dav1d libdav1d;  pc vpx libvpx;  pc kvazaar libkvazaar
hdr /usr/include/xvid.h libxvid
hdr /usr/include/lame/lame.h libmp3lame
pc fdk-aac libfdk-aac
pc opencore-amrnb libopencore-amrnb; pc opencore-amrwb libopencore-amrwb
pc vo-amrwbenc libvo-amrwbenc
pc opus libopus; pc vorbis libvorbis; pc theora libtheora; pc speex libspeex
pc libtwolame libtwolame; hdr /usr/include/shine/shine.h libshine; hdr /usr/include/gsm/gsm.h libgsm
pc libopenjp2 libopenjpeg; pc libwebp libwebp; pc libjxl libjxl; pc zbar libzbar
pc zvbi libzvbi; pc soxr libsoxr; pc rubberband librubberband; pc vidstab libvidstab
pc libvmaf libvmaf; pc zimg libzimg; pc libaribb24 libaribb24; pc libbluray libbluray
pc srt libsrt; pc rist librist; pc libssh libssh; pc libzmq libzmq
pc freetype2 libfreetype; pc fontconfig libfontconfig; pc fribidi libfribidi
pc harfbuzz libharfbuzz; pc ass libass
pc libcodec2 libcodec2; pc libmodplug libmodplug; pc libopenmpt libopenmpt; pc libmysofa libmysofa
pc libcurl libcurl; pc openssl openssl; pc libvpl libvpl; pc libva vaapi
pc libvvenc libvvenc
pc libv4l2 libv4l2; pc libxml-2.0 libxml2; pc whisper whisper
NV=()
if pkg-config --exists ffnvcodec; then NV+=(--enable-nvenc --enable-cuvid --enable-cuda-nvcc); fi
if [ -x "$NVCC" ]; then
  NV+=(--enable-libnpp --nvcc="$NVCC" --nvccflags="-gencode arch=compute_$CC,code=sm_$CC -O2")
fi
echo "enabled: ${E[*]} ${NV[*]}"

./configure --prefix=$PREFIX \
  --disable-debug --disable-doc --disable-ffplay \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-shared --enable-small --ld=g++ \
  --extra-cflags="-I$CUDA/include" --extra-ldflags="-L$CUDA/lib64" \
  "${E[@]}" "${NV[@]}"

log "make -j$JOBS"
make -j"$JOBS"

log "install -> $PREFIX"
su make install
su ldconfig

log "verify"
ffmpeg -hide_banner -version | head -3
echo "-- encoders:"; ffmpeg -hide_banner -encoders 2>/dev/null \
  | grep -iE 'nvenc|vpl|av1|x264|x265|kvazaar|xvid|aac|mp3' | head -30
echo "-- decoders:"; ffmpeg -hide_banner -decoders 2>/dev/null \
  | grep -iE 'av1|hevc|h264|cuvid' | head
echo "-- CUDA/QSV/whisper filters:"; ffmpeg -hide_banner -filters 2>/dev/null \
  | grep -iE 'npp|cuda|vpp_|whisper' | head
echo
echo "DONE: ffmpeg $TAG installed to $PREFIX/bin/ffmpeg"
