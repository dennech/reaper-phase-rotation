cmake_minimum_required(VERSION 3.15)
project(reaper_phaserot CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_library(reaper_phaserot SHARED
  src/phaserot.cpp
  vendor/WDL/fft.c
)
target_include_directories(reaper_phaserot PRIVATE vendor/sdk vendor)
target_compile_definitions(reaper_phaserot PRIVATE WDL_FFT_REALSIZE=8)
set_target_properties(reaper_phaserot PROPERTIES PREFIX "" OUTPUT_NAME "reaper_phaserot")

if(APPLE)
  set_target_properties(reaper_phaserot PROPERTIES SUFFIX ".dylib")
  target_compile_definitions(reaper_phaserot PRIVATE SWELL_PROVIDED_BY_APP)
  target_compile_options(reaper_phaserot PRIVATE -fvisibility=hidden)
elseif(UNIX)
  set_target_properties(reaper_phaserot PROPERTIES SUFFIX ".so")
  target_compile_definitions(reaper_phaserot PRIVATE SWELL_PROVIDED_BY_APP)
  target_compile_options(reaper_phaserot PRIVATE -fvisibility=hidden -fPIC)
elseif(WIN32)
  set_target_properties(reaper_phaserot PROPERTIES SUFFIX ".dll")
  target_compile_definitions(reaper_phaserot PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX)
endif()
