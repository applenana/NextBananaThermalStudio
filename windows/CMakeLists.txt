# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(banana_thermal LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "banana_thermal")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# ============================================================================
# Optional: bundle ffmpeg.exe alongside the runner so the in-app MP4 exporter
# can call it directly (no need for the user to have ffmpeg on PATH).
#
# Default: OFF (keeps Windows build fast and the distributable lean).
# To enable: set environment variable BUNDLE_FFMPEG=1 (CI release uses this).
#
# Strategy:
# - Cache the binary at windows/runner/bundled/ffmpeg.exe (gitignored).
# - First configure downloads BtbN's static GPL build (~130MB) and extracts
#   only ffmpeg.exe into the cache dir. Subsequent builds reuse the cache.
# - Both POST_BUILD (for `flutter run` / dev) and install() (for release
#   packaging) place ffmpeg.exe next to banana_thermal.exe.
# ============================================================================
set(FFMPEG_CACHE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/runner/bundled")
set(FFMPEG_EXE_CACHE "${FFMPEG_CACHE_DIR}/ffmpeg.exe")
set(FFMPEG_URL "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip")

if(DEFINED ENV{BUNDLE_FFMPEG} AND NOT "$ENV{BUNDLE_FFMPEG}" STREQUAL "0" AND NOT EXISTS "${FFMPEG_EXE_CACHE}")
  set(FFMPEG_ZIP "${CMAKE_BINARY_DIR}/_ffmpeg_dl/ffmpeg.zip")
  set(FFMPEG_EXTRACT_DIR "${CMAKE_BINARY_DIR}/_ffmpeg_dl/extracted")
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/_ffmpeg_dl")
  message(STATUS "[ffmpeg] BUNDLE_FFMPEG=1: downloading static build from BtbN (one-time, ~130MB) ...")
  file(DOWNLOAD "${FFMPEG_URL}" "${FFMPEG_ZIP}"
    SHOW_PROGRESS
    STATUS _ffmpeg_dl_status
    TLS_VERIFY ON
  )
  list(GET _ffmpeg_dl_status 0 _ffmpeg_dl_code)
  if(_ffmpeg_dl_code EQUAL 0)
    message(STATUS "[ffmpeg] Extracting ...")
    file(MAKE_DIRECTORY "${FFMPEG_EXTRACT_DIR}")
    file(ARCHIVE_EXTRACT INPUT "${FFMPEG_ZIP}" DESTINATION "${FFMPEG_EXTRACT_DIR}")
    file(GLOB_RECURSE _ffmpeg_found "${FFMPEG_EXTRACT_DIR}/*/bin/ffmpeg.exe")
    if(_ffmpeg_found)
      list(GET _ffmpeg_found 0 _ffmpeg_src)
      file(MAKE_DIRECTORY "${FFMPEG_CACHE_DIR}")
      file(COPY "${_ffmpeg_src}" DESTINATION "${FFMPEG_CACHE_DIR}")
      message(STATUS "[ffmpeg] Cached at ${FFMPEG_EXE_CACHE}")
    else()
      message(WARNING "[ffmpeg] ffmpeg.exe not found inside downloaded archive. MP4 export will fall back to PATH lookup.")
    endif()
  else()
    message(WARNING "[ffmpeg] Download failed (${_ffmpeg_dl_status}). MP4 export will fall back to PATH lookup.")
  endif()
endif()

if(EXISTS "${FFMPEG_EXE_CACHE}")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FFMPEG_EXE_CACHE}" "$<TARGET_FILE_DIR:${BINARY_NAME}>/ffmpeg.exe"
    COMMENT "Bundling ffmpeg.exe next to ${BINARY_NAME}")
  install(FILES "${FFMPEG_EXE_CACHE}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()
