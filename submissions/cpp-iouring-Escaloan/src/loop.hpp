// Event-loop lifecycle (implementation in loop.cpp).
#pragma once
#include "server.hpp"

bool loop_init(Loop& L, int id, const char* host, int port);
void loop_add_pg(Loop& L, int fd, bool is_write);
void loop_run(Loop& L);
