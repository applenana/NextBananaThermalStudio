# 构建最小化 ffmpeg.exe (仅 rawvideo → H.264 → MP4)

BtbN 的 GPL 静态包 ~95MB, 内含我们用不到的几十种 demuxer / encoder / filter.
本项目实际只用一条管线: 从 stdin 读 raw rgba/rgb24, 编码成 H.264, 封装 MP4.
按下面步骤自行编译, 产物 ffmpeg.exe 约 **8 – 15 MB**, 体积比 BtbN 缩到 1/10.

## 一、Windows: MSYS2 (推荐)

```bash
# 安装 MSYS2 后, 在 "MSYS2 MinGW x64" shell 中:
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
    mingw-w64-x86_64-toolchain \
    mingw-w64-x86_64-nasm \
    mingw-w64-x86_64-yasm \
    mingw-w64-x86_64-pkg-config \
    make git diffutils

# 编译 x264 静态库
git clone --depth 1 https://code.videolan.org/videolan/x264.git
cd x264
./configure --host=x86_64-w64-mingw32 --enable-static --disable-cli --disable-opencl
make -j$(nproc)
make install
cd ..

# 编译最小 ffmpeg
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git
cd ffmpeg
./configure \
    --arch=x86_64 \
    --target-os=mingw32 \
    --enable-gpl \
    --enable-libx264 \
    --enable-static \
    --disable-shared \
    --enable-small \
    --disable-debug \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --disable-everything \
    --enable-protocol=file \
    --enable-protocol=pipe \
    --enable-demuxer=rawvideo \
    --enable-decoder=rawvideo \
    --enable-encoder=libx264 \
    --enable-encoder=rawvideo \
    --enable-muxer=mp4 \
    --enable-muxer=mov \
    --enable-parser=h264 \
    --enable-bsf=h264_mp4toannexb \
    --enable-filter=scale \
    --enable-filter=format \
    --enable-filter=null \
    --enable-swscale \
    --enable-zlib
make -j$(nproc)
strip -s ffmpeg.exe
```

产物: `ffmpeg/ffmpeg.exe`, 约 8–15MB.

## 二、把产物放入项目

```powershell
# 在项目根:
mkdir windows/runner/bundled -Force
copy <msys2-build-path>/ffmpeg/ffmpeg.exe windows/runner/bundled/ffmpeg.exe
```

CMakeLists.txt 已配置: 一旦 `windows/runner/bundled/ffmpeg.exe` 存在,
每次 `flutter build windows` 都会把它复制到 release 目录, 与 banana_thermal.exe 同级.
打包成 zip 时只多出 ~10MB.

## 三、可选: UPX 进一步压缩

```powershell
# 安装 UPX (https://github.com/upx/upx/releases), 然后:
upx --best --lzma windows/runner/bundled/ffmpeg.exe
```

压缩后通常 3–6MB. 注意: UPX 可能触发部分杀软误报, 发布前测试一下.

## 四、CI 自动化思路

GitHub Actions 可以加一个 cache 步骤, key 为 ffmpeg 提交 hash:

```yaml
- name: Cache mini ffmpeg
  uses: actions/cache@v4
  with:
    path: windows/runner/bundled/ffmpeg.exe
    key: ffmpeg-mini-${{ hashFiles('tools/build-mini-ffmpeg.md') }}

- name: Build mini ffmpeg (if not cached)
  if: steps.cache-ffmpeg.outputs.cache-hit != 'true'
  shell: msys2 {0}
  run: |
    # 上面那些命令
```

## 五、规格清单 (本项目实际用到的 ffmpeg 能力)

- 输入: `-f rawvideo -pix_fmt rgba -s WxH -r FPS` (stdin pipe)
- 输出: `-c:v libx264 -pix_fmt yuv420p -preset medium -crf 23` (mp4)
- 滤镜: 隐式 swscale 颜色空间转换 (rgba → yuv420p)

不需要: 任何 audio codec, 任何 demuxer 除 rawvideo, 任何 muxer 除 mp4,
任何网络协议, hwaccel, libavdevice.
