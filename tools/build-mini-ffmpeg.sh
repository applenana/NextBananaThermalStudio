#!/usr/bin/env bash
# Build a minimal ffmpeg.exe for piping rawvideo -> libx264 mp4.
# Run inside MINGW64 shell (msys2_shell -mingw64).
set -eu -o pipefail

PREFIX="$HOME/ffmin/prefix"
SRC="$HOME/ffmin/src"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$PREFIX" "$SRC"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# --- x264 (static) ---
cd "$SRC"
if [ ! -d x264 ]; then
  git clone --depth=1 https://code.videolan.org/videolan/x264.git
fi
cd x264
make distclean 2>/dev/null || true
./configure \
  --prefix="$PREFIX" \
  --enable-static \
  --disable-cli \
  --disable-opencl \
  --disable-avs \
  --disable-swscale \
  --disable-lavf \
  --disable-ffms \
  --disable-gpac \
  --disable-lsmash \
  --bit-depth=8 \
  --chroma-format=420
make -j"$JOBS"
make install

# --- ffmpeg (minimal) ---
cd "$SRC"
if [ ! -d ffmpeg ]; then
  git clone --depth=1 https://git.ffmpeg.org/ffmpeg.git
fi
cd ffmpeg
make distclean 2>/dev/null || true

./configure \
  --prefix="$PREFIX" \
  --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib -static" \
  --enable-gpl \
  --enable-version3 \
  --enable-static \
  --disable-shared \
  --enable-small \
  --disable-debug \
  --disable-doc \
  --disable-htmlpages \
  --disable-manpages \
  --disable-podpages \
  --disable-txtpages \
  --disable-autodetect \
  --disable-everything \
  --disable-network \
  --disable-iconv \
  --disable-schannel \
  --disable-sdl2 \
  --disable-bzlib \
  --enable-zlib \
  --enable-swscale \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --enable-swresample \
  --enable-protocol=file,pipe \
  --enable-demuxer=rawvideo,mov,mp4 \
  --enable-decoder=rawvideo,h264 \
  --enable-parser=h264 \
  --enable-encoder=libx264,rawvideo \
  --enable-muxer=mp4,mov,rawvideo \
  --enable-filter=scale,format,null,copy,vflip \
  --enable-bsf=h264_mp4toannexb \
  --enable-libx264

make -j"$JOBS"

ls -lh ffmpeg.exe
strip ffmpeg.exe || true
ls -lh ffmpeg.exe
echo "Built: $(pwd)/ffmpeg.exe"
