/*
 * Written by Solar Designer <solar at openwall.com> in 2000-2011.
 * No copyright is claimed, and the software is hereby placed in the public
 * domain.  In case this attempt to disclaim copyright and place the software
 * in the public domain is deemed null and void, then the software is
 * Copyright (c) 2000-2011 Solar Designer and it is hereby released to the
 * general public under the following terms:
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted.
 *
 * There's ABSOLUTELY NO WARRANTY, express or implied.
 *
 * See crypt_blowfish.c for more information.
 */

#ifndef _CRYPT_BLOWFISH_H
#define _CRYPT_BLOWFISH_H

#include <stddef.h>

extern int _crypt_output_magic(const char *setting, char *output, int size);
extern char *_crypt_blowfish_rn(const char *key, const char *setting,
	char *output, int size);
extern char *_crypt_blowfish_len_rn(const char *key, size_t keylen,
	const char *setting, char *output, int size);
extern int _crypt_blowfish_decode(const char *input,
	unsigned char *output, int size);
extern int _crypt_blowfish_batch_selftest(void);
extern int _crypt_blowfish_batch_rn(const char *const *keys,
	const size_t *lengths, const char *const *settings,
	char (*outputs)[61], size_t count);
extern char *_crypt_gensalt_blowfish_rn(const char *prefix,
	unsigned long count,
	const char *input, int size, char *output, int output_size);

#endif
