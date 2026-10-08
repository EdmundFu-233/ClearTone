cmake_minimum_required(VERSION 3.24)
project(ClearTone VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

if(MSVC)
    add_compile_options(/utf-8 /W2)
else()
    add_compile_options(-Wall -Wextra -Wno-unused-parameter)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Network)
find_package(Qt6 QUIET COMPONENTS Multimedia Test)

option(CT_BUILD_TESTS "Build unit tests" ON)
option(CT_ENABLE_VLC "Use libVLC audio backend when the SDK is available" ON)

# ---------------------------------------------------------------------------
# libVLC (optional). Windows release packages ship vendor/vlc via scripts.
# ---------------------------------------------------------------------------
set(CT_VLC_ROOT "" CACHE PATH "libVLC SDK root (contains include/ and lib/)")
if(CT_ENABLE_VLC)
    find_path(CT_VLC_INCLUDE_DIR
        NAMES vlc/vlc.h
        HINTS "${CT_VLC_ROOT}/include" "$ENV{CT_VLC_ROOT}/include"
        PATHS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/vlc/include")
    find_library(CT_VLC_LIBRARY
        NAMES vlc libvlc
        HINTS "${CT_VLC_ROOT}/lib" "$ENV{CT_VLC_ROOT}/lib"
        PATHS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/vlc/lib")
    if(CT_VLC_INCLUDE_DIR AND CT_VLC_LIBRARY)
        set(CT_HAVE_LIBVLC ON)
        message(STATUS "libVLC found: ${CT_VLC_LIBRARY}")
    else()
        message(STATUS "libVLC not found; falling back to Qt Multimedia audio engine")
    endif()
endif()

# ---------------------------------------------------------------------------
# Core library: everything except main.cpp
# ---------------------------------------------------------------------------
file(GLOB_RECURSE CT_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/MainWindow.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/App/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Core/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/DesignSystem/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Features/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Playback/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Providers/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Rendering/*.cpp"
)
file(GLOB_RECURSE CT_HEADERS CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/MainWindow.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/App/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Core/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/DesignSystem/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Features/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Playback/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Providers/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/Rendering/*.h"
)

# OBJECT 库：保证 CT_REGISTER_PAGE 等静态注册不会在链接时被丢弃
# （静态库中无人引用的目标文件不会进可执行文件，页面会退化占位视图）。
add_library(cleartone_lib OBJECT ${CT_SOURCES} ${CT_HEADERS})
target_include_directories(cleartone_lib PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone")
target_link_libraries(cleartone_lib PUBLIC Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Network)

if(CT_HAVE_LIBVLC)
    target_compile_definitions(cleartone_lib PUBLIC CT_HAVE_LIBVLC)
    target_include_directories(cleartone_lib PRIVATE ${CT_VLC_INCLUDE_DIR})
    target_link_libraries(cleartone_lib PUBLIC ${CT_VLC_LIBRARY})
endif()

if(Qt6Multimedia_FOUND)
    target_compile_definitions(cleartone_lib PUBLIC CT_HAVE_QT_MULTIMEDIA)
    target_link_libraries(cleartone_lib PUBLIC Qt6::Multimedia)
endif()

if(WIN32)
    target_link_libraries(cleartone_lib PRIVATE crypt32)
endif()

# Resources (icons etc.) are compiled in through resources.qrc when present.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/resources.qrc")
    target_sources(cleartone_lib PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/resources.qrc")
endif()

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
add_executable(ClearTone WIN32 "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/main.cpp")
target_link_libraries(ClearTone PRIVATE cleartone_lib)

if(WIN32 AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/win/appicon.rc")
    target_sources(ClearTone PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/ClearTone/win/appicon.rc")
endif()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
if(CT_BUILD_TESTS AND Qt6Test_FOUND)
    enable_testing()
    add_subdirectory(tests)
endif()
