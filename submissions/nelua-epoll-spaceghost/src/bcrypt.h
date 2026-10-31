#ifndef NC_BCRYPT_H
#define NC_BCRYPT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define BC_MAXLANES 8
typedef struct {
    int cost;
    char prefix[7];
    char salt_txt[22];
    uint32_t salt[4];
    uint32_t key[18];
    char out[61];
    char setting[30]; /* Used only by the independent libxcrypt self-test. */
} bc_req_t;
int bc_prepare(bc_req_t *request, const char *password, const char *setting);
void bc_compute(bc_req_t *requests, int count);
int bc_selftest(int rounds);

/* True means a full cost-10 hash was copied into out. False asks the caller to
 * use its normal libxcrypt path: unsupported settings/Unicode countermeasures,
 * thread setup failure, shutdown, or a full bounded queue. No verification result
 * or password survives the synchronous call. */
bool nc_bcrypt_hash(const char *password, const char *setting, char out[61]);
#endif
