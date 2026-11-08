cmake_minimum_required(VERSION 3.15)
project(silique_windows_updater LANGUAGES CXX)
add_library(silique_windows_updater STATIC windows_updater.cpp)
apply_standard_settings(silique_windows_updater)
target_compile_definitions(silique_windows_updater PRIVATE NOMINMAX)
target_include_directories(silique_windows_updater PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(silique_windows_updater PUBLIC bcrypt shell32 advapi32 ole32 version uuid psapi)

add_executable(silique_update_guard update_guard.cpp)
apply_standard_settings(silique_update_guard)
set_property(TARGET silique_update_guard PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
target_link_options(silique_update_guard PRIVATE "/MANIFESTUAC:level='asInvoker' uiAccess='false'")
target_link_libraries(silique_update_guard PRIVATE advapi32)
set_target_properties(silique_update_guard PROPERTIES RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:${BINARY_NAME}>")

configure_file(native_test.rc.in "${CMAKE_CURRENT_BINARY_DIR}/native_test.rc" @ONLY)
add_executable(silique_windows_updater_test EXCLUDE_FROM_ALL windows_updater_test.cpp windows_updater.cpp "${CMAKE_CURRENT_BINARY_DIR}/native_test.rc")
apply_standard_settings(silique_windows_updater_test)
target_compile_definitions(silique_windows_updater_test PRIVATE NOMINMAX SILIQUE_UPDATER_DIAGNOSTICS)
target_link_libraries(silique_windows_updater_test PRIVATE bcrypt shell32 advapi32 ole32 version uuid psapi)
set_target_properties(silique_windows_updater_test PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/updater_tests/$<CONFIG>")
add_dependencies(silique_windows_updater_test silique_update_guard)

# Negative control, never bundled: reproduce the reviewed attribute-only,
# writable-sharing ancestor bug. CI must observe the barrier test fail on this
# executable before it may accept the exact same test against production code.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/windows_updater.cpp" NEGATIVE_CONTROL_SOURCE)
string(REPLACE "FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL,\n      FILE_SHARE_READ,"
  "FILE_READ_ATTRIBUTES,\n      FILE_SHARE_READ | FILE_SHARE_WRITE,"
  NEGATIVE_CONTROL_SOURCE "${NEGATIVE_CONTROL_SOURCE}")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/windows_updater.cpp" PRODUCTION_SOURCE)
if(NEGATIVE_CONTROL_SOURCE STREQUAL PRODUCTION_SOURCE)
  message(FATAL_ERROR "Updater ancestor-lock negative control no longer matches production")
endif()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/weak_directory_pin.cpp" "${NEGATIVE_CONTROL_SOURCE}")
add_executable(silique_windows_updater_negative_control EXCLUDE_FROM_ALL
  windows_updater_test.cpp "${CMAKE_CURRENT_BINARY_DIR}/weak_directory_pin.cpp"
  "${CMAKE_CURRENT_BINARY_DIR}/native_test.rc")
apply_standard_settings(silique_windows_updater_negative_control)
target_compile_definitions(silique_windows_updater_negative_control PRIVATE NOMINMAX)
target_include_directories(silique_windows_updater_negative_control PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(silique_windows_updater_negative_control PRIVATE bcrypt shell32 advapi32 ole32 version uuid psapi)
set_target_properties(silique_windows_updater_negative_control PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/updater_tests/$<CONFIG>")
