/* Minimal standalone portability definitions for the unmodified bcrypt core. */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#define INCLUDE_bcrypt 1
#define INCLUDE_bcrypt_a 0
#define INCLUDE_bcrypt_x 0
#define INCLUDE_bcrypt_y 0
#define ARG_UNUSED(x) x __attribute__((unused))
#define CRYPT_OUTPUT_SIZE 64
#define ALG_SPECIFIC_SIZE 8192
#define XCRYPT_USE_BIGENDIAN (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
