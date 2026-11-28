cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "desktop_registry.cpp"
  "desktop_shell.cpp"
  "drop_target.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "media_session.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
# Shell integration: tray / notifications (shell32), lock-screen session
# events (wtsapi32), OLE drag and drop (ole32) and the WinRT media overlay
# through WRL (runtimeobject, the header-only alternative to windowsapp.lib
# that works with this runner's no-exceptions build).
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "wtsapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "runtimeobject.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Discord status through Discord's SDK, when its files are in place (see the
# parent CMakeLists.txt). Delay-loaded, so the app still starts when the DLL is
# missing or cannot be loaded on that PC.
if(ZANGETSU_HAS_DISCORD_SDK)
  target_sources(${BINARY_NAME} PRIVATE "discord_presence.cpp")
  target_compile_definitions(${BINARY_NAME} PRIVATE "ZANGETSU_DISCORD_SDK")
  target_include_directories(${BINARY_NAME} PRIVATE "${ZANGETSU_DISCORD_SDK_DIR}")
  target_link_libraries(${BINARY_NAME} PRIVATE
    "${ZANGETSU_DISCORD_SDK_DIR}/discord_partner_sdk.lib"
    "delayimp.lib")
  target_link_options(${BINARY_NAME} PRIVATE
    "/DELAYLOAD:discord_partner_sdk.dll")
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
