//go:build !purego

#include "textflag.h"

DATA jsonQuotes<>+0(SB)/8, $0x2222222222222222
DATA jsonQuotes<>+8(SB)/8, $0x2222222222222222
GLOBL jsonQuotes<>(SB), RODATA|NOPTR, $16
DATA jsonSlashes<>+0(SB)/8, $0x5c5c5c5c5c5c5c5c
DATA jsonSlashes<>+8(SB)/8, $0x5c5c5c5c5c5c5c5c
GLOBL jsonSlashes<>(SB), RODATA|NOPTR, $16
DATA jsonSpaces<>+0(SB)/8, $0x2020202020202020
DATA jsonSpaces<>+8(SB)/8, $0x2020202020202020
GLOBL jsonSpaces<>(SB), RODATA|NOPTR, $16

// A signed comparison with space also catches every high-bit byte. Combine
// that mask with quotes/backslashes, then return the first marked byte.
TEXT ·firstJSONSpecialSSE2(SB), NOSPLIT, $0-24
	MOVQ value_base+0(FP), SI
	MOVQ value_len+8(FP), CX
	LEAQ -16(SI)(CX*1), DI
	MOVQ SI, R8
	MOVOU jsonQuotes<>(SB), X1
	MOVOU jsonSlashes<>(SB), X2
	MOVOU jsonSpaces<>(SB), X3
nextBlock:
	CMPQ R8, DI
	JAE lastBlock
	MOVOU (R8), X0
	MOVOU X0, X4
	PCMPEQB X1, X4
	MOVOU X0, X5
	PCMPEQB X2, X5
	POR X5, X4
	MOVOU X3, X5
	PCMPGTB X0, X5
	POR X5, X4
	PMOVMSKB X4, AX
	TESTL AX, AX
	JNZ found
	ADDQ $16, R8
	JMP nextBlock
lastBlock:
	MOVQ DI, R8
	MOVOU (R8), X0
	MOVOU X0, X4
	PCMPEQB X1, X4
	MOVOU X0, X5
	PCMPEQB X2, X5
	POR X5, X4
	MOVOU X3, X5
	PCMPGTB X0, X5
	POR X5, X4
	PMOVMSKB X4, AX
	TESTL AX, AX
	JNZ found
	MOVQ CX, ret+16(FP)
	RET
found:
	BSFL AX, AX
	SUBQ SI, R8
	ADDQ AX, R8
	MOVQ R8, ret+16(FP)
	RET
