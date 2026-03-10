#!/usr/bin/env bash

set -exuo pipefail

# Handle 'clean' subcommand: remove all build artifacts
if [[ "${1:-}" == "clean" ]]; then
  ROOT="${2:-$HOME}"
  echo "Cleaning FFmpeg build artifacts from $ROOT ..."
  rm -rf "$ROOT/ffmpeg" "$ROOT/x264" "$ROOT/SVT-AV1" "$ROOT/dav1d" \
         "$ROOT/compiled" "$ROOT/nv-codec-headers" "$ROOT/libvpl" \
         "$ROOT/nasm-2.14.02" "$ROOT/x265" "$ROOT/libvpx"
  rm -f  "$ROOT"/zlib-*.tar.gz "$ROOT"/nasm-*.tar.gz
  rm -rf "$ROOT"/zlib-*/
  echo "Done."
  exit 0
fi

ROOT="${1:-$HOME}"
NPROC="${NPROC:-$(nproc)}"
EXTRA_CFLAGS=""
EXTRA_LDFLAGS=""
EXTRA_X264_FLAGS=""
EXTRA_FFMPEG_FLAGS=""
BUILD_TAGS="${BUILD_TAGS:-}"

# Build platform flags
BUILDOS=$(uname -s | tr '[:upper:]' '[:lower:]')
BUILDARCH=$(uname -m | tr '[:upper:]' '[:lower:]')
if [[ $BUILDARCH == "aarch64" ]]; then
  BUILDARCH=arm64
fi
if [[ $BUILDARCH == "x86_64" ]]; then
  BUILDARCH=amd64
fi

# Override these for cross-compilation
export GOOS="${GOOS:-$BUILDOS}"
export GOARCH="${GOARCH:-$BUILDARCH}"

echo "BUILDOS: $BUILDOS"
echo "BUILDARCH: $BUILDARCH"
echo "GOOS: $GOOS"
echo "GOARCH: $GOARCH"

function check_sysroot() {
  if ! stat $SYSROOT >/dev/null; then
    echo "cross-compilation sysroot not found at $SYSROOT, try setting SYSROOT to the correct path"
    exit 1
  fi
}

if [[ "$BUILDARCH" == "amd64" && "$BUILDOS" == "linux" && "$GOARCH" == "arm64" && "$GOOS" == "linux" ]]; then
  echo "cross-compiling linux-amd64 --> linux-arm64"
  export CC="clang-14"
  export STRIP="llvm-strip-14"
  export AR="llvm-ar-14"
  export RANLIB="llvm-ranlib-14"
  export CFLAGS="--target=aarch64-linux-gnu"
  export LDFLAGS="--target=aarch64-linux-gnu"
  EXTRA_CFLAGS="--target=aarch64-linux-gnu -I/usr/local/cuda_arm64/include $EXTRA_CFLAGS"
  EXTRA_LDFLAGS="-fuse-ld=lld --target=aarch64-linux-gnu -L/usr/local/cuda_arm64/lib64 $EXTRA_LDFLAGS"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --arch=aarch64 --enable-cross-compile --cc=clang-14 --strip=llvm-strip-14"
  HOST_OS="--host=aarch64-linux-gnu"
fi

if [[ "$BUILDARCH" == "arm64" && "$BUILDOS" == "darwin" && "$GOARCH" == "arm64" && "$GOOS" == "linux" ]]; then
  SYSROOT="${SYSROOT:-"/tmp/sysroot-aarch64-linux-gnu"}"
  check_sysroot
  echo "cross-compiling darwin-arm64 --> linux-arm64"
  LLVM_PATH="${LLVM_PATH:-/opt/homebrew/opt/llvm/bin}"
  if [[ ! -f "$LLVM_PATH/ld.lld" ]]; then
    echo "llvm linker not found at '$LLVM_PATH/ld.lld'. try 'brew install llvm' or set LLVM_PATH to your LLVM bin directory"
    exit 1
  fi
  export CC="$LLVM_PATH/clang --sysroot=$SYSROOT"
  export AR="/opt/homebrew/opt/llvm/bin/llvm-ar"
  export RANLIB="/opt/homebrew/opt/llvm/bin/llvm-ranlib"
  EXTRA_CFLAGS="--target=aarch64-linux-gnu $EXTRA_CFLAGS"
  EXTRA_LDFLAGS="--target=aarch64-linux-gnu -fuse-ld=$LLVM_PATH/ld.lld $EXTRA_LDFLAGS"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --arch=aarch64 --enable-cross-compile --cc=$LLVM_PATH/clang --sysroot=$SYSROOT --ar=$AR --ranlib=$RANLIB --target-os=linux"
  EXTRA_X264_FLAGS="$EXTRA_X264_FLAGS --sysroot=$SYSROOT --ar=$AR --ranlib=$RANLIB"
  HOST_OS="--host=aarch64-linux-gnu"
fi

if [[ "$BUILDOS" == "linux" && "$GOARCH" == "amd64" && "$GOOS" == "windows" ]]; then
  echo "cross-compiling linux-$BUILDARCH --> windows-amd64"
  SYSROOT="${SYSROOT:-"/usr/x86_64-w64-mingw32"}"
  check_sysroot
  EXTRA_CFLAGS="-L$SYSROOT/lib -I$SYSROOT/include  $EXTRA_CFLAGS"
  EXTRA_LDFLAGS="-L$SYSROOT/lib $EXTRA_LDFLAGS"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --arch=x86_64 --enable-cross-compile --cross-prefix=x86_64-w64-mingw32- --target-os=mingw64 --sysroot=$SYSROOT"
  EXTRA_X264_FLAGS="$EXTRA_X264_FLAGS --cross-prefix=x86_64-w64-mingw32- --sysroot=$SYSROOT"
  HOST_OS="--host=mingw64"
  # Workaround for https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=967969
  export PKG_CONFIG_LIBDIR="/usr/local/x86_64-w64-mingw32/lib/pkgconfig"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --pkg-config=$(which pkg-config)"
fi

if [[ "$BUILDARCH" == "amd64" && "$BUILDOS" == "darwin" && "$GOARCH" == "arm64" && "$GOOS" == "darwin" ]]; then
  echo "cross-compiling darwin-amd64 --> darwin-arm64"
  EXTRA_CFLAGS="$EXTRA_CFLAGS --target=arm64-apple-macos11"
  EXTRA_LDFLAGS="$EXTRA_LDFLAGS --target=arm64-apple-macos11"
  HOST_OS="--host=aarch64-darwin"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --arch=aarch64 --enable-cross-compile"
fi

# Windows (MSYS2) needs a few tweaks
if [[ "$BUILDOS" == *"MSYS"* ]]; then
  ROOT="/build"
  export PATH="$PATH:/usr/bin:/mingw64/bin"
  export C_INCLUDE_PATH="${C_INCLUDE_PATH:-}:/mingw64/lib"

  export PATH="$ROOT/compiled/bin":$PATH
  export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig

  export TARGET_OS="--target-os=mingw64"
  export HOST_OS="--host=x86_64-w64-mingw32"
  export BUILD_OS="--build=x86_64-w64-mingw32 --host=x86_64-w64-mingw32 --target=x86_64-w64-mingw32"

  # Needed for mbedtls
  export WINDOWS_BUILD=1
fi

export PATH="$ROOT/compiled/bin:${PATH}"
export PKG_CONFIG_PATH="$ROOT/compiled/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

mkdir -p "$ROOT/"

# NVENC only works on Windows/Linux
if [[ "$GOOS" != "darwin" ]]; then
  if [[ ! -e "$ROOT/nv-codec-headers" ]]; then
    git clone --depth 1 --single-branch --branch n12.2.72.0 https://github.com/FFmpeg/nv-codec-headers.git "$ROOT/nv-codec-headers"
    cd $ROOT/nv-codec-headers
    make -e PREFIX="$ROOT/compiled"
    make install -e PREFIX="$ROOT/compiled"
  fi
fi

if [[ "$GOOS" != "windows" && "$GOARCH" == "amd64" ]]; then
  if [[ ! -e "$ROOT/nasm-2.14.02" ]]; then
    # sudo apt-get -y install asciidoc xmlto # this fails :(
    cd "$ROOT"
    curl -o nasm-2.14.02.tar.gz "https://gstreamer.freedesktop.org/src/mirror/nasm-2.14.02.tar.xz"
    echo 'e24ade3e928f7253aa8c14aa44726d1edf3f98643f87c9d72ec1df44b26be8f5  nasm-2.14.02.tar.gz' >nasm-2.14.02.tar.gz.sha256
    sha256sum -c nasm-2.14.02.tar.gz.sha256
    tar xf nasm-2.14.02.tar.gz
    rm nasm-2.14.02.tar.gz nasm-2.14.02.tar.gz.sha256
    cd "$ROOT/nasm-2.14.02"
    ./configure --prefix="$ROOT/compiled"
    make -j$NPROC
    make -j$NPROC install || echo "Installing docs fails but should be OK otherwise"
  fi
fi

if [[ ! -e "$ROOT/x264" ]]; then
  git clone http://git.videolan.org/git/x264.git "$ROOT/x264"
  cd "$ROOT/x264"
  if [[ $GOARCH == "arm64" ]]; then
    # newer git master, compiles on Apple Silicon
    git checkout 66a5bc1bd1563d8227d5d18440b525a09bcf17ca
  else
    # older git master, does not compile on Apple Silicon
    git checkout 545de2ffec6ae9a80738de1b2c8cf820249a2530
  fi
  ./configure --prefix="$ROOT/compiled" --enable-pic --enable-static ${HOST_OS:-} --disable-cli --extra-cflags="$EXTRA_CFLAGS" --extra-asflags="$EXTRA_CFLAGS" --extra-ldflags="$EXTRA_LDFLAGS" $EXTRA_X264_FLAGS || (cat $ROOT/x264/config.log && exit 1)
  make -j$NPROC
  make -j$NPROC install-lib-static
fi

if [[ ! -e "$ROOT/zlib-1.3.1" ]]; then
  cd "$ROOT"
  curl -fL -o zlib-1.3.1.tar.gz https://zlib.net/fossils/zlib-1.3.1.tar.gz \
    || curl -fL -o zlib-1.3.1.tar.gz https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
  tar xf zlib-1.3.1.tar.gz
  cd zlib-1.3.1
  ./configure --prefix="$ROOT/compiled" --static
  make -j$NPROC
  make -j$NPROC install
fi

# AV1 dependencies: cmake (for SVT-AV1), meson + ninja (for dav1d)
for tool in cmake meson ninja; do
  if ! command -v $tool &>/dev/null; then
    echo "ERROR: $tool is required for AV1 codec builds but not found. Install it and retry."
    exit 1
  fi
done

# Determine cross-compilation target parameters for cmake/meson
CROSS_COMPILING=false
if [[ "$GOARCH" != "$BUILDARCH" || "$GOOS" != "$BUILDOS" ]]; then
  CROSS_COMPILING=true
fi

# Map GOOS/GOARCH to cmake/meson values
case "$GOARCH" in
  arm64) TARGET_CPU_FAMILY="aarch64"; TARGET_CPU="aarch64" ;;
  amd64) TARGET_CPU_FAMILY="x86_64";  TARGET_CPU="x86_64" ;;
  *)     TARGET_CPU_FAMILY="$GOARCH"; TARGET_CPU="$GOARCH" ;;
esac
case "$GOOS" in
  linux)   CMAKE_SYSTEM="Linux";   MESON_SYSTEM="linux" ;;
  windows) CMAKE_SYSTEM="Windows"; MESON_SYSTEM="windows" ;;
  darwin)  CMAKE_SYSTEM="Darwin";  MESON_SYSTEM="darwin" ;;
  *)       CMAKE_SYSTEM="$GOOS";   MESON_SYSTEM="$GOOS" ;;
esac

# Resolve the cross compiler binaries. CC may be unset (windows uses cross-prefix),
# or may contain flags ("clang-14 --sysroot=..."). Extract just the binary.
# We also derive CXX from CC since cmake tests both C and CXX compilers.
if [[ -n "${CC:-}" ]]; then
  CROSS_CC_BIN="${CC%% *}"
  # Derive C++ compiler: clang-14 -> clang++-14, gcc -> g++, cc -> c++
  case "$CROSS_CC_BIN" in
    *clang*) CROSS_CXX_BIN="${CROSS_CC_BIN/clang/clang++}" ;;
    *gcc*)   CROSS_CXX_BIN="${CROSS_CC_BIN/gcc/g++}" ;;
    *)       CROSS_CXX_BIN="" ;;
  esac
elif [[ "$GOOS" == "windows" ]]; then
  CROSS_CC_BIN="x86_64-w64-mingw32-gcc"
  CROSS_CXX_BIN="x86_64-w64-mingw32-g++"
else
  CROSS_CC_BIN=""
  CROSS_CXX_BIN=""
fi

# SVT-AV1 (software AV1 encoder)
if [[ ! -e "$ROOT/compiled/lib/pkgconfig/SvtAv1Enc.pc" ]]; then
  rm -rf "$ROOT/SVT-AV1"
  git clone --depth 1 --branch v2.3.0 https://gitlab.com/AOMediaCodec/SVT-AV1.git "$ROOT/SVT-AV1"
  cd "$ROOT/SVT-AV1"
  mkdir -p Build && cd Build
  SVT_CMAKE_ARGS=(-GNinja "-DCMAKE_INSTALL_PREFIX=$ROOT/compiled" -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
    -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF)
  if $CROSS_COMPILING; then
    SVT_CMAKE_ARGS+=("-DCMAKE_SYSTEM_NAME=$CMAKE_SYSTEM" "-DCMAKE_SYSTEM_PROCESSOR=$TARGET_CPU")
    if [[ -n "$CROSS_CC_BIN" ]]; then SVT_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=$CROSS_CC_BIN"); fi
    if [[ -n "$CROSS_CXX_BIN" ]]; then SVT_CMAKE_ARGS+=("-DCMAKE_CXX_COMPILER=$CROSS_CXX_BIN"); fi
    if [[ -n "${AR:-}" ]]; then SVT_CMAKE_ARGS+=("-DCMAKE_AR=$(command -v $AR)"); fi
    if [[ -n "${EXTRA_CFLAGS:-}" ]]; then
      SVT_CMAKE_ARGS+=("-DCMAKE_C_FLAGS=$EXTRA_CFLAGS" "-DCMAKE_CXX_FLAGS=$EXTRA_CFLAGS" "-DCMAKE_ASM_FLAGS=$EXTRA_CFLAGS")
    fi
  fi
  cmake .. "${SVT_CMAKE_ARGS[@]}"
  ninja -C .
  ninja -C . install
fi

# dav1d (software AV1 decoder)
if [[ ! -e "$ROOT/compiled/lib/pkgconfig/dav1d.pc" ]]; then
  rm -rf "$ROOT/dav1d"
  git clone --depth 1 --branch 1.5.0 https://code.videolan.org/videolan/dav1d.git "$ROOT/dav1d"
  cd "$ROOT/dav1d"
  DAV1D_MESON_FLAGS="--prefix=$ROOT/compiled --libdir=lib --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false"
  if $CROSS_COMPILING; then
    # Derive windres for Windows cross-compile
    WINDRES_BIN="${CROSS_CC_BIN:+${CROSS_CC_BIN/gcc/windres}}"
    cat > cross_file.txt <<EOF
[binaries]
c = '${CROSS_CC_BIN:-cc}'
ar = '${AR:-ar}'
strip = '${STRIP:-strip}'
windres = '${WINDRES_BIN:-windres}'

[properties]
needs_exe_wrapper = true

[host_machine]
system = '$MESON_SYSTEM'
cpu_family = '$TARGET_CPU_FAMILY'
cpu = '$TARGET_CPU'
endian = 'little'
EOF
    DAV1D_MESON_FLAGS="$DAV1D_MESON_FLAGS --cross-file cross_file.txt"
  fi
  meson setup build $DAV1D_MESON_FLAGS
  ninja -C build
  ninja -C build install
fi

# oneVPL dispatcher (for Intel QSV support) — x86-only, not macOS
if [[ "$GOOS" != "darwin" && "$GOARCH" == "amd64" ]]; then
  if [[ ! -e "$ROOT/compiled/lib/pkgconfig/vpl.pc" ]]; then
    rm -rf "$ROOT/libvpl"
    git clone --depth 1 --branch v2.13.0 https://github.com/intel/libvpl.git "$ROOT/libvpl"
    cd "$ROOT/libvpl"
    mkdir -p _build && cd _build
    VPL_CMAKE_ARGS=(-GNinja "-DCMAKE_INSTALL_PREFIX=$ROOT/compiled" -DCMAKE_INSTALL_LIBDIR=lib
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
      -DBUILD_TESTS=OFF -DINSTALL_DEV=ON -DINSTALL_LIB=ON
      -DBUILD_EXAMPLES=OFF -DINSTALL_EXAMPLES=OFF)
    if $CROSS_COMPILING; then
      VPL_CMAKE_ARGS+=("-DCMAKE_SYSTEM_NAME=$CMAKE_SYSTEM" "-DCMAKE_SYSTEM_PROCESSOR=$TARGET_CPU")
      if [[ -n "$CROSS_CC_BIN" ]]; then VPL_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=$CROSS_CC_BIN"); fi
      if [[ -n "$CROSS_CXX_BIN" ]]; then VPL_CMAKE_ARGS+=("-DCMAKE_CXX_COMPILER=$CROSS_CXX_BIN"); fi
      if [[ -n "${AR:-}" ]]; then VPL_CMAKE_ARGS+=("-DCMAKE_AR=$(command -v $AR)"); fi
      if [[ -n "${EXTRA_CFLAGS:-}" ]]; then
        VPL_CMAKE_ARGS+=("-DCMAKE_C_FLAGS=$EXTRA_CFLAGS" "-DCMAKE_CXX_FLAGS=$EXTRA_CFLAGS")
      fi
    fi
    cmake .. "${VPL_CMAKE_ARGS[@]}"
    ninja -C .
    ninja -C . install
    # Static linking: dispatcher is C++, consumers need -lstdc++
    if ! grep -q 'lstdc++' "$ROOT/compiled/lib/pkgconfig/vpl.pc"; then
      echo "Libs.private: -lstdc++" >> "$ROOT/compiled/lib/pkgconfig/vpl.pc"
    fi
  fi
fi

if [[ "$GOOS" == "linux" && "$BUILD_TAGS" == *"debug-video"* ]]; then
  sudo apt-get install -y libnuma-dev cmake
  if [[ ! -e "$ROOT/x265" ]]; then
    git clone https://bitbucket.org/multicoreware/x265_git.git "$ROOT/x265"
    cd "$ROOT/x265"
    git checkout 17839cc0dc5a389e27810944ae2128a65ac39318
    cd build/linux/
    cmake -DCMAKE_INSTALL_PREFIX=$ROOT/compiled -G "Unix Makefiles" ../../source
    make -j$NPROC
    make -j$NPROC install
  fi
  # VP8/9 support
  if [[ ! -e "$ROOT/libvpx" ]]; then
    git clone https://chromium.googlesource.com/webm/libvpx.git "$ROOT/libvpx"
    cd "$ROOT/libvpx"
    git checkout ab35ee100a38347433af24df05a5e1578172a2ae
    ./configure --prefix="$ROOT/compiled" --disable-examples --disable-unit-tests --enable-vp9-highbitdepth --enable-shared --as=nasm
    make -j$NPROC
    make -j$NPROC install
  fi
fi

DISABLE_FFMPEG_COMPONENTS=""
EXTRA_FFMPEG_LDFLAGS="$EXTRA_LDFLAGS"
# all flags which should be present for production build, but should be replaced/removed for debug build
DEV_FFMPEG_FLAGS=""

if [[ "$BUILDOS" == "darwin" && "$GOOS" == "darwin" ]]; then
  EXTRA_FFMPEG_LDFLAGS="$EXTRA_FFMPEG_LDFLAGS -framework CoreFoundation -framework Security -framework VideoToolbox -framework CoreMedia -framework CoreVideo"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --enable-videotoolbox --enable-encoder=h264_videotoolbox,hevc_videotoolbox --enable-filter=scale_vt,hwupload"
elif [[ "$GOOS" == "windows" ]]; then
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --enable-d3d11va --enable-cuda --enable-cuda-llvm --enable-cuvid --enable-nvenc --enable-decoder=h264_cuvid,hevc_cuvid,vp8_cuvid,vp9_cuvid,av1_cuvid --enable-filter=scale_cuda,hwupload_cuda --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc"
elif [[ -e "/usr/local/cuda/lib64" ]]; then
  echo "CUDA SDK detected, building with GPU support"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --enable-nonfree --enable-cuda-nvcc --enable-libnpp --enable-cuda --enable-cuda-llvm --enable-cuvid --enable-nvdec --enable-nvenc --enable-decoder=h264_cuvid,hevc_cuvid,vp8_cuvid,vp9_cuvid,av1_cuvid --enable-filter=scale_npp,hwupload_cuda --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc"
else
  echo "No CUDA SDK detected, building without GPU support"
fi

# VA-API support (Linux amd64 only, required as backend for QSV)
if [[ "$GOOS" == "linux" && "$GOARCH" == "amd64" ]] && [[ -f /usr/include/va/va.h || -f /usr/local/include/va/va.h ]]; then
  echo "VA-API detected, enabling hardware acceleration backend"
  EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --enable-vaapi"
fi

# QSV support (not on macOS)
if [[ "$GOOS" != "darwin" ]]; then
  if pkg-config --exists vpl 2>/dev/null; then
    echo "Intel oneVPL detected, building with QSV support"
    EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --enable-libvpl --enable-decoder=h264_qsv,hevc_qsv,vp9_qsv,av1_qsv --enable-encoder=h264_qsv,hevc_qsv,vp9_qsv,av1_qsv --enable-filter=scale_qsv,vpp_qsv,hwupload"
  elif pkg-config --exists libmfx 2>/dev/null; then
    echo "Intel Media SDK detected, building with QSV support"
    EXTRA_FFMPEG_FLAGS="$EXTRA_FFMPEG_FLAGS --enable-libmfx --enable-decoder=h264_qsv,hevc_qsv,vp9_qsv --enable-encoder=h264_qsv,hevc_qsv,vp9_qsv --enable-filter=scale_qsv,vpp_qsv,hwupload"
  fi
fi

if [[ $BUILD_TAGS == *"debug-video"* ]]; then
  echo "video debug mode, building ffmpeg with tools, debug info and additional capabilities for running tests"
  DEV_FFMPEG_FLAGS="--enable-muxer=md5 --enable-demuxer=hls --enable-filter=ssim,tinterlace --enable-encoder=wrapped_avframe,pcm_s16le "
  DEV_FFMPEG_FLAGS+="--enable-shared --enable-debug=3 --disable-stripping --disable-optimizations --enable-encoder=libx265,libvpx_vp8,libvpx_vp9,libsvtav1 "
  DEV_FFMPEG_FLAGS+="--enable-decoder=hevc,libvpx_vp8,libvpx_vp9,libdav1d --enable-libx265 --enable-libvpx --enable-bsf=noise "
else
  # disable all unnecessary features for production build
  DISABLE_FFMPEG_COMPONENTS+=" --disable-doc --disable-sdl2 --disable-iconv --disable-muxers --disable-demuxers --disable-parsers --disable-protocols "
  DISABLE_FFMPEG_COMPONENTS+=" --disable-encoders --disable-decoders --disable-filters --disable-bsfs --disable-lzma "
fi

# Extra libs for static linking — Windows uses Win32 threads, not pthreads
FFMPEG_EXTRA_LIBS="-lm"
if [[ "$GOOS" != "windows" ]]; then
  FFMPEG_EXTRA_LIBS="$FFMPEG_EXTRA_LIBS -lpthread"
fi

if [[ ! -e "$ROOT/ffmpeg/libavcodec/libavcodec.a" ]]; then
  git clone https://github.com/Livepeer-FrameWorks/FFmpeg.git "$ROOT/ffmpeg" || echo "FFmpeg dir already exists"
  cd "$ROOT/ffmpeg"
  git checkout 6a5a1152ec55fe9db1c0af72c3eaa458ba11d07e
  ./configure ${TARGET_OS:-} $DISABLE_FFMPEG_COMPONENTS --fatal-warnings \
    --enable-libx264 --enable-libsvtav1 --enable-libdav1d --enable-gpl \
    --enable-protocol=rtmp,file,pipe \
    --enable-muxer=mp3,wav,flac,mpegts,hls,segment,mp4,hevc,matroska,webm,flv,null --enable-demuxer=mp3,wav,flac,flv,mpegts,mp4,mov,webm,matroska,image2 \
    --enable-bsf=h264_mp4toannexb,aac_adtstoasc,h264_metadata,h264_redundant_pps,hevc_mp4toannexb,extract_extradata,av1_metadata \
    --enable-parser=mpegaudio,vorbis,opus,flac,aac,aac_latm,h264,hevc,vp8,vp9,av1,png \
    --enable-filter=abuffer,buffer,abuffersink,buffersink,afifo,fifo,aformat,format \
    --enable-filter=aresample,asetnsamples,fps,scale,hwdownload,select \
    --enable-encoder=mp3,vorbis,flac,aac,opus,libx264,libsvtav1 \
    --enable-decoder=mp3,vorbis,flac,aac,opus,h264,libdav1d,png \
    --extra-cflags="${EXTRA_CFLAGS} -I${ROOT}/compiled/include -I/usr/local/cuda/include" \
    --extra-ldflags="${EXTRA_FFMPEG_LDFLAGS} -L${ROOT}/compiled/lib -L/usr/local/cuda/lib64" \
    --extra-libs="$FFMPEG_EXTRA_LIBS" \
    --pkg-config-flags="--static" \
    --prefix="$ROOT/compiled" \
    $EXTRA_FFMPEG_FLAGS \
    $DEV_FFMPEG_FLAGS || (tail -100 ${ROOT}/ffmpeg/ffbuild/config.log && exit 1)
  # If configure fails, then print the last 100 log lines for debugging and exit.
fi

if [[ ! -e "$ROOT/ffmpeg/libavcodec/libavcodec.a" || $BUILD_TAGS == *"debug-video"* ]]; then
  cd "$ROOT/ffmpeg"
  make -j$NPROC
  make -j$NPROC install
fi
