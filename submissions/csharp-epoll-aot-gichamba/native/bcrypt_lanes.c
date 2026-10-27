/*
 * Interleaved bcrypt: several cost-10 hashes in one call.
 *
 * This file includes Openwall's crypt_blowfish.c unchanged and reuses its tables, key
 * setup and encoding. Only the expensive key-expansion loop is new: it advances up to 8
 * hashes together, so the CPU can overlap the independent Blowfish chains.
 */
#include <stdlib.h>
#include <string.h>

#include "crypt_blowfish.c"

/* Most hashes one call interleaves. */
#define CONDUIT_MAX_LANES 8
/* Smallest output buffer for one hash: the 7-character prefix, 22 salt characters, 31 hash characters and a NUL. */
#define CONDUIT_HASH_SIZE (7 + 22 + 31 + 1)
/* Two-word blocks one body pass encrypts: the P array (BF_N + 2 words) then the four S-boxes. */
#define CONDUIT_BODY_BLOCKS ((BF_N + 2) / 2 + 4 * 0x100 / 2)

/* Working state of one hash: Blowfish state, expanded key, salt words and the round count (2^cost). */
typedef struct {
	BF_ctx ctx;
	BF_key expanded_key;
	BF_word salt[4];
	BF_word count;
} Lane;

/* Blowfish F function. */
#define LF(c, x) \
	(((((c)->S[0][(x) >> 24] + (c)->S[1][((x) >> 16) & 0xFF]) ^ \
	(c)->S[2][((x) >> 8) & 0xFF]) + (c)->S[3][(x) & 0xFF]))

/* Encrypts one block with the given state. */
static inline void lane_encrypt(const BF_ctx *c, BF_word *pl, BF_word *pr)
{
	BF_word L = *pl, R = *pr, t;
	int i;

	L ^= c->P[0];
	for (i = 0; i < BF_N; i += 2) {
		R ^= c->P[i + 1] ^ LF(c, L);
		L ^= c->P[i + 2] ^ LF(c, R);
	}
	t = R;
	R = L;
	L = t ^ c->P[BF_N + 1];
	*pl = L;
	*pr = R;
}

/*
 * The BF_body() step for n lanes at once: encrypts a zero block through the whole P
 * array and all four S-boxes, feeding each output back into the state. Forced inline so
 * that n is a constant at every call site and the lane loops unroll.
 */
static inline __attribute__((always_inline)) void body_n(int n, Lane *lane)
{
	BF_word L[CONDUIT_MAX_LANES], R[CONDUIT_MAX_LANES], t;
	int l, i, blk;

#pragma GCC unroll 8
	for (l = 0; l < n; l++)
		L[l] = R[l] = 0;

	for (blk = 0; blk < CONDUIT_BODY_BLOCKS; blk++) {
#pragma GCC unroll 8
		for (l = 0; l < n; l++)
			L[l] ^= lane[l].ctx.P[0];
		for (i = 0; i < BF_N; i += 2) {
#pragma GCC unroll 8
			for (l = 0; l < n; l++)
				R[l] ^= lane[l].ctx.P[i + 1] ^ LF(&lane[l].ctx, L[l]);
#pragma GCC unroll 8
			for (l = 0; l < n; l++)
				L[l] ^= lane[l].ctx.P[i + 2] ^ LF(&lane[l].ctx, R[l]);
		}
#pragma GCC unroll 8
		for (l = 0; l < n; l++) {
			t = R[l];
			R[l] = L[l];
			L[l] = t ^ lane[l].ctx.P[BF_N + 1];
		}
		if (blk < (BF_N + 2) / 2) {
#pragma GCC unroll 8
			for (l = 0; l < n; l++) {
				lane[l].ctx.P[2 * blk] = L[l];
				lane[l].ctx.P[2 * blk + 1] = R[l];
			}
		} else {
			int k = 2 * (blk - (BF_N + 2) / 2);
#pragma GCC unroll 8
			for (l = 0; l < n; l++) {
				((BF_word *)lane[l].ctx.S)[k] = L[l];
				((BF_word *)lane[l].ctx.S)[k + 1] = R[l];
			}
		}
	}
}

/* The main loop of BF_crypt for n lanes that share one cost. */
static inline __attribute__((always_inline)) void expand_n(int n, Lane *lane)
{
	BF_word count = lane[0].count;
	int l, i;

	do {
#pragma GCC unroll 8
		for (l = 0; l < n; l++)
			for (i = 0; i < BF_N + 2; i++)
				lane[l].ctx.P[i] ^= lane[l].expanded_key[i];
		body_n(n, lane);
#pragma GCC unroll 8
		for (l = 0; l < n; l++) {
			for (i = 0; i < BF_N; i += 4) {
				lane[l].ctx.P[i] ^= lane[l].salt[0];
				lane[l].ctx.P[i + 1] ^= lane[l].salt[1];
				lane[l].ctx.P[i + 2] ^= lane[l].salt[2];
				lane[l].ctx.P[i + 3] ^= lane[l].salt[3];
			}
			lane[l].ctx.P[16] ^= lane[l].salt[0];
			lane[l].ctx.P[17] ^= lane[l].salt[1];
		}
		body_n(n, lane);
	} while (--count);
}

/* Same checks and setup as BF_crypt, up to the main loop. Returns -1 on a bad setting. */
static int lane_init(Lane *ln, const char *key, const char *setting)
{
	BF_word L, R, *ptr;
	int i;

	if (setting[0] != '$' || setting[1] != '2' ||
	    setting[2] < 'a' || setting[2] > 'z' ||
	    !flags_by_subtype[(unsigned int)(unsigned char)setting[2] - 'a'] ||
	    setting[3] != '$' ||
	    setting[4] < '0' || setting[4] > '3' ||
	    setting[5] < '0' || setting[5] > '9' ||
	    (setting[4] == '3' && setting[5] > '1') ||
	    setting[6] != '$')
		return -1;

	ln->count = (BF_word)1 << ((setting[4] - '0') * 10 + (setting[5] - '0'));
	if (ln->count < 16 || BF_decode(ln->salt, &setting[7], 16))
		return -1;
	BF_swap(ln->salt, 4);

	BF_set_key(key, ln->expanded_key, ln->ctx.P,
	    flags_by_subtype[(unsigned int)(unsigned char)setting[2] - 'a']);
	memcpy(ln->ctx.S, BF_init_state.S, sizeof(ln->ctx.S));

	L = R = 0;
	for (i = 0; i < BF_N + 2; i += 2) {
		L ^= ln->salt[i & 2];
		R ^= ln->salt[(i & 2) + 1];
		lane_encrypt(&ln->ctx, &L, &R);
		ln->ctx.P[i] = L;
		ln->ctx.P[i + 1] = R;
	}

	ptr = ln->ctx.S[0];
	do {
		ptr += 4;
		L ^= ln->salt[(BF_N + 2) & 3];
		R ^= ln->salt[(BF_N + 3) & 3];
		lane_encrypt(&ln->ctx, &L, &R);
		*(ptr - 4) = L;
		*(ptr - 3) = R;

		L ^= ln->salt[(BF_N + 4) & 3];
		R ^= ln->salt[(BF_N + 5) & 3];
		lane_encrypt(&ln->ctx, &L, &R);
		*(ptr - 2) = L;
		*(ptr - 1) = R;
	} while (ptr < &ln->ctx.S[3][0xFF]);

	return 0;
}

/* Encrypts the magic string 64 times and writes the final hash text. */
static void lane_finish(Lane *ln, const char *setting, char *output)
{
	BF_word out[6], L, R;
	int i, count;

	for (i = 0; i < 6; i += 2) {
		L = BF_magic_w[i];
		R = BF_magic_w[i + 1];
		for (count = 0; count < 64; count++)
			lane_encrypt(&ln->ctx, &L, &R);
		out[i] = L;
		out[i + 1] = R;
	}

	memcpy(output, setting, 7 + 22 - 1);
	output[7 + 22 - 1] = BF_itoa64[(int)
		BF_atoi64[(int)setting[7 + 22 - 1] - 0x20] & 0x30];
	BF_swap(out, 6);
	BF_encode(&output[7 + 22], out, 23);
	output[7 + 22 + 31] = '\0';
}

/*
 * Wipes and frees n lanes, which hold key schedules derived from the passwords. explicit_bzero,
 * unlike a memset just before free, cannot be removed by the optimizer.
 */
static void lanes_free(Lane *lane, int n)
{
	explicit_bzero(lane, sizeof(Lane) * (size_t)n);
	free(lane);
}

/* One bcrypt per lane through the unmodified crypt_blowfish entry point. */
static int hash_singly(int n, const char *const *keys, const char *const *settings,
	char **outputs, int output_size)
{
	int i, rc = 0;

	for (i = 0; i < n; i++)
		if (!_crypt_blowfish_rn(keys[i], settings[i], outputs[i], output_size))
			rc = -1;
	return rc;
}

/*
 * Hashes n (1 to 8) passwords. keys[i] is a NUL-terminated password, settings[i] a
 * "$2a$10$" plus 22 salt characters string, outputs[i] a buffer of output_size (at least
 * 61) bytes that receives the 60-character hash. Returns 0 when every lane produced a
 * hash; otherwise -1, and the failed lanes hold "*0" or "*1". One lane, or lanes with
 * different costs or a bad setting, go through the stock crypt_blowfish code.
 */
int conduit_bcrypt_lanes(int n, const char *const *keys, const char *const *settings,
	char **outputs, int output_size)
{
	Lane *lane;
	int i, same_cost = 1;

	if (n < 1 || n > CONDUIT_MAX_LANES || output_size < CONDUIT_HASH_SIZE)
		return -1;
	if (n == 1)
		return hash_singly(n, keys, settings, outputs, output_size);

	lane = (Lane *)malloc(sizeof(Lane) * (size_t)n);
	if (!lane)
		return -1;

	for (i = 0; i < n; i++) {
		if (lane_init(&lane[i], keys[i], settings[i])) {
			same_cost = 0;
			break;
		}
		if (lane[i].count != lane[0].count)
			same_cost = 0;
	}
	if (!same_cost) {
		lanes_free(lane, n);
		return hash_singly(n, keys, settings, outputs, output_size);
	}

	switch (n) {
	case 2: expand_n(2, lane); break;
	case 3: expand_n(3, lane); break;
	case 4: expand_n(4, lane); break;
	case 5: expand_n(5, lane); break;
	case 6: expand_n(6, lane); break;
	case 7: expand_n(7, lane); break;
	default: expand_n(8, lane); break;
	}

	for (i = 0; i < n; i++)
		lane_finish(&lane[i], settings[i], outputs[i]);

	lanes_free(lane, n);
	return 0;
}

/*
 * Writes a "$2a$<cost>$<22 salt characters>" setting from 16 raw salt bytes into output
 * (at least 30 bytes). Returns 0, or -1 on bad arguments.
 */
int conduit_bcrypt_gensalt(int cost, const unsigned char *salt16, char *output, int output_size)
{
	return _crypt_gensalt_blowfish_rn("$2a", (unsigned long)cost, (const char *)salt16, 16,
		output, output_size) ? 0 : -1;
}
