cmake_minimum_required(VERSION 3.16)
project(conduit CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# No functional-test venv: we don't use userver's testsuite.
set(USERVER_FEATURE_TESTSUITE OFF CACHE BOOL "" FORCE)
find_package(userver 3.2 REQUIRED COMPONENTS core)
# What find_package(... postgresql) does, minus UserverSql.cmake: that only sets up a pip venv for SQL code
# generation, which we don't use, and would download unpinned Python packages at configure time.
include("${USERVER_CMAKE_DIR}/SetupPostgresqlDeps.cmake")
find_package(OpenSSL REQUIRED)

add_executable(conduit
    src/main.cpp
    src/api.cpp
    src/auth.cpp
    src/util.cpp
    src/users.cpp
    src/profiles.cpp
    src/articles.cpp
    src/comments.cpp
)
target_include_directories(conduit PRIVATE src)
target_link_libraries(conduit PRIVATE userver::postgresql OpenSSL::Crypto crypt)
# SHA256_* low-level calls are deprecated in OpenSSL 3 but still the fastest way to reuse precomputed HMAC pads.
target_compile_options(conduit PRIVATE -Wno-deprecated-declarations)
