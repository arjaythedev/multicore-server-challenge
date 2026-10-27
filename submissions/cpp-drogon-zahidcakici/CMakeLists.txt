cmake_minimum_required(VERSION 3.16)
project(conduit C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Drogon CONFIG REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(PQ REQUIRED IMPORTED_TARGET libpq)

# bcrypt core: C, compiled for this CPU
add_library(bcrypt STATIC native/bcrypt.c)
set_target_properties(bcrypt PROPERTIES C_STANDARD 11 C_EXTENSIONS ON)
target_compile_options(bcrypt PRIVATE -O3 -march=native)

add_executable(conduit src/main.cc src/db.cc src/jwt.cc src/bcrypt_pool.cc)
target_compile_options(conduit PRIVATE -O3 -march=native -Wall -Wno-deprecated-declarations)
target_link_libraries(conduit PRIVATE Drogon::Drogon PkgConfig::PQ bcrypt jemalloc)
