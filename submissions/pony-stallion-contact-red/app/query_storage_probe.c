#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdatomic.h>

typedef int64_t (*ledger_getter)(uint32_t, uint32_t);

int64_t conduit_query_storage_read(uint32_t record, uint32_t field) {
  ledger_getter getter;
  *(void **)(&getter) = dlsym(RTLD_DEFAULT, "conduit_query_storage_ledger_get");
  return getter ? getter(record, field) : INT64_MIN;
}

extern void *ponyint_pagemap_get_chunk(const void *address);
int conduit_query_storage_registered(uintptr_t address) {
  return ponyint_pagemap_get_chunk((const void *)address) != 0;
}

static _Atomic uintptr_t finalized;
void conduit_query_storage_final(void) {
  atomic_fetch_add_explicit(&finalized, 1, memory_order_relaxed);
}
uintptr_t conduit_query_storage_final_count(void) {
  return atomic_load_explicit(&finalized, memory_order_relaxed);
}
