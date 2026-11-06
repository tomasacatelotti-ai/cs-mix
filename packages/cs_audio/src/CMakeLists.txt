cmake_minimum_required(VERSION 3.10)
project(cs_audio_library VERSION 0.2.0 LANGUAGES C CXX)

# LAME (only the MP3 encoder) as its own static library: it has its own config.h,
# which must not be confused with chromaprint's.
add_library(cs_lame STATIC
  lame/VbrTag.c
  lame/bitstream.c
  lame/encoder.c
  lame/fft.c
  lame/gain_analysis.c
  lame/id3tag.c
  lame/lame.c
  lame/newmdct.c
  lame/presets.c
  lame/psymodel.c
  lame/quantize.c
  lame/quantize_pvt.c
  lame/reservoir.c
  lame/set_get.c
  lame/tables.c
  lame/takehiro.c
  lame/util.c
  lame/vbrquantize.c
  lame/version.c
)
set_target_properties(cs_lame PROPERTIES POSITION_INDEPENDENT_CODE ON C_VISIBILITY_PRESET hidden)
target_include_directories(cs_lame PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/lame)
target_compile_definitions(cs_lame PRIVATE HAVE_CONFIG_H)
if (MSVC)
  target_compile_options(cs_lame PRIVATE /O2 /wd4244 /wd4305 /wd4996)
  target_compile_definitions(cs_lame PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(cs_lame PRIVATE -O2 -w)
endif()

set(CP chromaprint)
add_library(cs_audio SHARED
  "cs_audio.cpp"
  "convert.cpp"
  "miniaudio_impl.c"
  ${CP}/audio_processor.cpp ${CP}/chroma.cpp ${CP}/chroma_resampler.cpp ${CP}/chroma_filter.cpp
  ${CP}/spectrum.cpp ${CP}/fft.cpp ${CP}/fingerprinter.cpp ${CP}/image_builder.cpp ${CP}/simhash.cpp
  ${CP}/silence_remover.cpp ${CP}/fingerprint_calculator.cpp ${CP}/fingerprint_compressor.cpp
  ${CP}/fingerprint_decompressor.cpp ${CP}/fingerprinter_configuration.cpp ${CP}/fingerprint_matcher.cpp
  ${CP}/chromaprint.cpp ${CP}/fft_lib_kissfft.cpp ${CP}/utils/base64.cpp
  ${CP}/avresample/resample2.c
  ${CP}/kissfft/kiss_fft.c ${CP}/kissfft/kiss_fftr.c
)

set_target_properties(cs_audio PROPERTIES
  PUBLIC_HEADER cs_audio.h
  OUTPUT_NAME "cs_audio"
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
)

target_include_directories(cs_audio PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/${CP}
  ${CMAKE_CURRENT_SOURCE_DIR}/${CP}/kissfft
)

# Same feature switches for every file that includes miniaudio.h.
target_compile_definitions(cs_audio PRIVATE
  DART_SHARED_LIB
  MA_NO_ENCODING
  MA_NO_GENERATION
  MA_NO_ENGINE
  MA_NO_NODE_GRAPH
  MA_NO_RESOURCE_MANAGER
  HAVE_CONFIG_H
  CHROMAPRINT_NODLL
  _USE_MATH_DEFINES
)

if (MSVC)
  target_compile_options(cs_audio PRIVATE /O2 /utf-8)
  target_compile_definitions(cs_audio PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(cs_audio PRIVATE -O2 -fvisibility=hidden)
endif()

target_link_libraries(cs_audio PRIVATE cs_lame)

if (ANDROID)
  # Support Android 15 16k page size devices.
  target_link_options(cs_audio PRIVATE "-Wl,-z,max-page-size=16384")
  find_library(log-lib log)
  find_library(mediandk-lib mediandk)
  target_link_libraries(cs_audio PRIVATE ${log-lib} ${mediandk-lib})
elseif (WIN32)
  # Media Foundation decodes the audio of MP4/M4A downloads.
  target_link_libraries(cs_audio PRIVATE mfplat mfreadwrite mfuuid ole32)
elseif (UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(cs_audio PRIVATE Threads::Threads dl m)
endif()
