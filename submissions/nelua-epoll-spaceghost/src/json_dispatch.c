#include "native.h"
#include "json_scan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef size_t (*nc_scan_fn)(unsigned char *,size_t);
static nc_scan_fn selected;
#ifdef NC_APP_C
#define NC_PICK(c_function,nelua_function) (c_function)
#else
#define NC_PICK(c_function,nelua_function) (nelua?(nelua_function):(c_function))
#endif

/* Called once, before any worker starts. The selected pointer never changes
 * while requests run. An unsupported forced ISA fails startup rather than
 * executing illegal instructions or silently changing the experiment. */
bool nc_json_scan_init(void)
{
    const char *mode=getenv("JSON_SCAN");
    selected=NULL;
    if (!mode || !*mode) {
#ifdef NC_APP_C
        mode="c-auto";
#else
        mode="nelua-auto";
#endif
    }
    if (!strcmp(mode,"legacy")) return true;
    __builtin_cpu_init();
    bool avx2=__builtin_cpu_supports("avx2");
    bool avx512=avx2 && __builtin_cpu_supports("avx512f") && __builtin_cpu_supports("avx512bw");
    bool nelua=!strncmp(mode,"nelua-",6), c=!strncmp(mode,"c-",2);
#ifdef NC_APP_C
    if (nelua) goto invalid;
#endif
    const char *kernel=mode+(nelua?6:c?2:0);
    if (!nelua && !c) goto invalid;
    if (!strcmp(kernel,"auto")) kernel=avx512?"avx512":avx2?"avx2":"word";
    if (!strcmp(kernel,"scalar")) selected=NC_PICK(nc_json_prefix_scalar_c,nc_json_prefix_scalar_nelua);
    else if (!strcmp(kernel,"word")) selected=NC_PICK(nc_json_prefix_word_c,nc_json_prefix_word_nelua);
    else if (!strcmp(kernel,"avx2") && avx2) selected=NC_PICK(nc_json_prefix_avx2_c,nc_json_prefix_avx2_nelua);
    else if (!strcmp(kernel,"avx512") && avx512) selected=NC_PICK(nc_json_prefix_avx512_c,nc_json_prefix_avx512_nelua);
    else goto invalid;
    return true;
invalid:
    fprintf(stderr,"JSON_SCAN must be legacy or {c,nelua}-{auto,scalar,word,avx2,avx512}; forced ISA must be supported\n");
    return false;
}

bool nc_json_scan_enabled(void) { return selected!=NULL; }
size_t nc_json_scan_prefix(unsigned char *p,size_t n) { return selected(p,n); }
