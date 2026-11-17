cmake_minimum_required(VERSION 3.14)
project(cb360_restore LANGUAGES CXX)
add_subdirectory(../super_resolution ${CMAKE_CURRENT_BINARY_DIR}/super_resolution)
add_library(cb360_restore SHARED bridge.cpp
  core/src/processing/photo.cpp
  core/src/display/photo_renderer.cpp
  core/src/display/thermal_raster.cpp
  core/src/display/thermal_overlay.cpp
  core/src/ui/overlay_font.cpp
  core/src/ui/calibration_popup_font.cpp
  core/src/display/view.cpp
  core/src/processing/temperature.cpp
  core/src/processing/stripe_suppression.cpp
  core/src/processing/nuc.cpp
  core/src/protocol/parameter_line.cpp
)
target_include_directories(cb360_restore PRIVATE core/include)
target_compile_features(cb360_restore PRIVATE cxx_std_17)
if(MSVC)
 target_compile_options(cb360_restore PRIVATE /utf-8)
 target_compile_definitions(cb360_restore PRIVATE NOMINMAX)
endif()
