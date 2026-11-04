cmake_minimum_required(VERSION 3.10)
project(cs_audio_library VERSION 0.1.0 LANGUAGES C CXX)

add_library(cs_audio SHARED
  "cs_audio.cpp"
  "miniaudio_impl.c"
)

set_target_properties(cs_audio PROPERTIES
  PUBLIC_HEADER cs_audio.h
  OUTPUT_NAME "cs_audio"
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
)

# Same feature switches for every file that includes miniaudio.h.
target_compile_definitions(cs_audio PRIVATE
  DART_SHARED_LIB
  MA_NO_ENCODING
  MA_NO_GENERATION
  MA_NO_ENGINE
  MA_NO_NODE_GRAPH
  MA_NO_RESOURCE_MANAGER
)

if (MSVC)
  target_compile_options(cs_audio PRIVATE /O2 /utf-8)
else()
  target_compile_options(cs_audio PRIVATE -O2 -fvisibility=hidden)
endif()

if (ANDROID)
  # Support Android 15 16k page size devices.
  target_link_options(cs_audio PRIVATE "-Wl,-z,max-page-size=16384")
  find_library(log-lib log)
  target_link_libraries(cs_audio PRIVATE ${log-lib})
elseif (UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(cs_audio PRIVATE Threads::Threads dl m)
endif()
