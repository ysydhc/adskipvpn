cmake_minimum_required(VERSION 3.5.0)
project(adskip_bridge)

add_library(adskip_bridge SHARED adskip_bridge.cpp)
target_link_libraries(adskip_bridge PUBLIC libace_napi.z.so)
