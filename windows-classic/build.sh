#!/usr/bin/env bash
# Builds CS Mix Clásico (Windows 7+, 32 bits) with MinGW-w64 from Linux.
# Usage: windows-classic/build.sh [version]   → windows-classic/out/CSMixClasico.exe
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:-0.1}"
CXX=${CXX:-i686-w64-mingw32-g++-posix}
CC=${CC:-i686-w64-mingw32-gcc-posix}
WINDRES=${WINDRES:-i686-w64-mingw32-windres}
ENG=../packages/cs_audio/src
OUT=out
mkdir -p "$OUT/obj"
# -march=k8: the oldest CPUs this targets (Athlon 64 / Turion) have SSE2 but not SSE3 everywhere.
FLAGS="-O2 -march=k8 -msse2 -mfpmath=sse -D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DUNICODE -D_UNICODE \
  -DCSA_NO_CHROMAPRINT -DCSA_SAFE_LATENCY -DMA_NO_ENCODING -DMA_NO_GENERATION -DMA_NO_ENGINE -DMA_NO_NODE_GRAPH \
  -DMA_NO_RESOURCE_MANAGER -D_USE_MATH_DEFINES -DNOMINMAX -DWIN32_LEAN_AND_MEAN -DAPP_VERSION=\"$VER\""
[ -f "$OUT/obj/miniaudio.o" ] || $CC $FLAGS -c $ENG/miniaudio_impl.c -o "$OUT/obj/miniaudio.o"
for f in kiss_fft kiss_fftr; do $CC $FLAGS -c $ENG/chromaprint/kissfft/$f.c -o "$OUT/obj/$f.o"; done
for f in $ENG/cs_audio.cpp src/*.cpp; do
  $CXX $FLAGS -I$ENG -I$ENG/chromaprint/kissfft -std=c++17 -Wall -Wno-unused-function -c "$f" -o "$OUT/obj/$(basename "${f%.*}").o"
done
$WINDRES -I res res/app.rc -O coff -o "$OUT/obj/app.res.o"
$CXX -o "$OUT/CSMixClasico.exe" "$OUT"/obj/*.o -municode -mwindows -static -static-libgcc -static-libstdc++ \
  -lws2_32 -lcomctl32 -lshell32 -lole32 -luuid -lgdi32 -luser32 -ladvapi32 -lwinmm -s
echo "OK: $OUT/CSMixClasico.exe"
