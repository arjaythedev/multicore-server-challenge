cmake_minimum_required(VERSION 3.15)
project(multicore)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)

find_package(Drogon REQUIRED)
find_package(Jsoncpp REQUIRED)

add_executable(${PROJECT_NAME}
        src/controllers/UsersController.cpp
        src/controllers/UsersController.hpp
        src/controllers/ProfilesController.cpp
        src/controllers/ProfilesController.hpp
        src/controllers/ArticlesController.cpp
        src/controllers/ArticlesController.hpp
        src/controllers/FavoritesController.cpp
        src/controllers/FavoritesController.hpp
        src/controllers/CommentsController.cpp
        src/controllers/CommentsController.hpp
        src/controllers/TagsController.cpp
        src/controllers/TagsController.hpp
        src/middleware/AuthCheckMiddleware.hpp
        src/controllers/Common.hpp
        src/controllers/bcrypt.hpp
        src/controllers/bcrypt_tables.cpp
        src/main.cpp
        src/db/Sql.cpp
        src/db/Sql.hpp
        src/controllers/robin_hood.h
        src/controllers/BCryptPool.hpp
)

target_include_directories(${PROJECT_NAME} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
        "${JSONCPP_INCLUDE_DIRS}"
        "${DROGON_INCLUDE_DIRS}"
)

target_link_libraries(${PROJECT_NAME} Drogon::Drogon)

find_library(JEMALLOC_LIB jemalloc)
if(JEMALLOC_LIB)
    message(STATUS "jemalloc: ${JEMALLOC_LIB}")
    target_link_libraries(${PROJECT_NAME} ${JEMALLOC_LIB})
else()
    message(WARNING "jemalloc not found, using glibc malloc")
endif()

target_compile_options(${PROJECT_NAME} PRIVATE
        $<$<CONFIG:Release>:
        -O3
        -march=native
        -fno-plt
        -fno-semantic-interposition
        -fvisibility=hidden
        -fvisibility-inlines-hidden
        -ffunction-sections
        -fdata-sections
        -flto=auto
        >
)

target_link_options(${PROJECT_NAME} PRIVATE
        $<$<CONFIG:Release>:
        -flto=auto
        -Wl,-O1
        -Wl,--as-needed
        -Wl,-z,now
        -Wl,--gc-sections
        >
)

add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
        $<TARGET_FILE_DIR:${PROJECT_NAME}>/config
        COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_CURRENT_SOURCE_DIR}/config
        $<TARGET_FILE_DIR:${PROJECT_NAME}>/config
        COMMENT "Copying config directory to output directory"
)

message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Executable directory: $<TARGET_FILE_DIR:${PROJECT_NAME}>")