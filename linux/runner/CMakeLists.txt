cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "bluetooth_classic_plugin.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# BlueZ (libbluetooth) + GIO for the native Bluetooth Classic (RFCOMM) plugin
# used by the Bluetooth-radio audio backend.
#
# Note: the "bluez" apt package is only the daemon/tools; the headers and
# bluez.pc pkg-config file come from libbluetooth-dev. Try pkg-config first,
# then fall back to locating the header/library directly.
find_package(PkgConfig REQUIRED)
pkg_check_modules(BLUEZ IMPORTED_TARGET bluez)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)

if(NOT BLUEZ_FOUND)
  find_path(BLUETOOTH_INCLUDE_DIR bluetooth/bluetooth.h)
  find_library(BLUETOOTH_LIBRARY bluetooth)
  if(NOT BLUETOOTH_INCLUDE_DIR OR NOT BLUETOOTH_LIBRARY)
    message(FATAL_ERROR
      "BlueZ development files not found. The 'bluez' package is only the "
      "daemon; the build needs the headers/library:\n"
      "  sudo apt install libbluetooth-dev\n"
      "(Fedora: bluez-libs-devel, Arch: bluez-libs)")
  endif()
endif()

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
if(BLUEZ_FOUND)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::BLUEZ)
else()
  target_include_directories(${BINARY_NAME} PRIVATE "${BLUETOOTH_INCLUDE_DIR}")
  target_link_libraries(${BINARY_NAME} PRIVATE "${BLUETOOTH_LIBRARY}")
endif()
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GIO)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
