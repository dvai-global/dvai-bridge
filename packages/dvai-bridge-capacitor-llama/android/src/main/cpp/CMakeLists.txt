cmake_minimum_required(VERSION 3.22)
project("dvai_capacitor_llama")

# Path to the vendored llama.cpp submodule
set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/llama.cpp")

# llama.cpp build configuration for Android
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)  # OpenMP not on stock Android NDK

# Vulkan backend on arm64; CPU on others
if(${ANDROID_ABI} STREQUAL "arm64-v8a")
    # Disabled by default - requires Vulkan SDK headers; can enable later
    # set(GGML_VULKAN ON CACHE BOOL "" FORCE)
endif()

add_subdirectory(${LLAMA_CPP_DIR} ${CMAKE_CURRENT_BINARY_DIR}/llama_cpp_build)

# Our JNI bridge
add_library(dvai_capacitor_llama SHARED jni-bridge.cpp)
target_link_libraries(dvai_capacitor_llama
    PRIVATE llama
    PRIVATE log
    PRIVATE android
)
target_include_directories(dvai_capacitor_llama
    PRIVATE ${LLAMA_CPP_DIR}/include
    PRIVATE ${LLAMA_CPP_DIR}/ggml/include
)
