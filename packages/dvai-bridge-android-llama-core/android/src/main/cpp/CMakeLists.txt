cmake_minimum_required(VERSION 3.22)
project("dvai_android_llama_core")

# Path to the vendored llama.cpp submodule (co-located in native/llama.cpp)
set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/native/llama.cpp")

# llama.cpp build configuration for Android
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)  # OpenMP not on stock Android NDK

# Phase 2A Pass 1: enable LLAMA_BUILD_TOOLS so the `mtmd` library target is
# registered. We only need the mtmd library itself; the surrounding CLI
# executables are still built (they're cheap on Android NDK and link cleanly
# against llama-common, which is also built when LLAMA_BUILD_COMMON is on by
# default). If any tools subdirectory becomes problematic on a future submodule
# bump, switch to a more surgical approach (e.g. add_subdirectory on just
# tools/mtmd).
set(LLAMA_BUILD_TOOLS ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)

# Vulkan backend on arm64; CPU on others
if(${ANDROID_ABI} STREQUAL "arm64-v8a")
    # Disabled by default - requires Vulkan SDK headers; can enable later
    # set(GGML_VULKAN ON CACHE BOOL "" FORCE)
endif()

add_subdirectory(${LLAMA_CPP_DIR} ${CMAKE_CURRENT_BINARY_DIR}/llama_cpp_build)

# Our JNI bridge
add_library(dvai_android_llama_core SHARED jni-bridge.cpp)
target_link_libraries(dvai_android_llama_core
    PRIVATE llama
    # Phase 2A Pass 1: link against mtmd so jni-bridge.cpp can call its
    # symbols. Pass 1 only #includes the headers and uses no symbols at
    # runtime; the linker is happy as long as no undefined references exist.
    PRIVATE mtmd
    PRIVATE log
    PRIVATE android
)
target_include_directories(dvai_android_llama_core
    PRIVATE ${LLAMA_CPP_DIR}/include
    PRIVATE ${LLAMA_CPP_DIR}/ggml/include
    # mtmd headers (mtmd.h, mtmd-helper.h, ...) live alongside the source.
    PRIVATE ${LLAMA_CPP_DIR}/tools/mtmd
)
