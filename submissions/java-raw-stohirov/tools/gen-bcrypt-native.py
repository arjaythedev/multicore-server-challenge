#!/usr/bin/env python3
"""Generates bcrypt's expand0 kernels for K hashes in lockstep, for native/:

    python3 tools/gen-bcrypt-native.py asm > native/bc_x86_64.S
    python3 tools/gen-bcrypt-native.py c   > native/bc_kernels.h

native/bc.c runs the cost loop over them; src/conduit/BCryptNative.java calls it. The plain C kernels are the fallback
for CPUs without BMI and for other architectures.

Each kernel takes n contiguous lanes of 1042 words (P[18], then S[4][256]; stride 4168 bytes) with the key already
XORed into P. It encrypts a zero block and writes its 521 chained outputs over P and S in turn.

The assembly is a port of rust-epoll-WorriedArrow's build.rs, itself a port of nick-potts's asm_gen.zig
(zig-iouring-nick-potts): one base register reaches every lane, five lanes keep their halves in registers and further
lanes on the stack. Needs BMI1 and BMI2. Two styles of S-box index extraction, picked per CPU at startup:
  ah:    byte 0 by movzx from the low byte, byte 1 by bextr, bytes 2 and 3 by one rorx then movzx from al and ah
  bextr: byte 3 by a copy and a shift, bytes 2 and 1 by bextr, byte 0 by movzx; no partial register reads
"""
import sys

MAX_ASM = 6
MAX_C = 6
WORDS = 18 + 4 * 256
STRIDE = WORDS * 4
ENCRYPTIONS = WORDS // 2
REG_LANES = 5
HALVES = [["ebx", "ebp"], ["r8d", "r9d"], ["r10d", "r11d"], ["r12d", "r13d"], ["r14d", "r15d"]]
LOW = [["bl", "bpl"], ["r8b", "r9b"], ["r10b", "r11b"], ["r12b", "r13b"], ["r14b", "r15b"]]


def slot(u, h):
    return 8 + 8 * (u - REG_LANES) + 4 * h


def half_round(o, style, u, hx, r):
    """y ^= P[r] ^ F(x) for lane u, where x is half hx and y the other."""
    base = u * STRIDE
    s = base + 72
    hy = 1 - hx
    if u < REG_LANES:
        x, y = HALVES[u][hx], HALVES[u][hy]
        o.append(f"  xor {y}, dword ptr [rdi + {base + 4 * r}]")
        if style == "ah":
            o.append(f"  rorx eax, {x}, 16")
            o.append("  movzx esi, ah")
            o.append(f"  mov edx, dword ptr [rdi + rsi*4 + {s}]")
            o.append("  movzx esi, al")
        else:
            o.append(f"  mov esi, {x}")
            o.append("  shr esi, 24")
            o.append(f"  mov edx, dword ptr [rdi + rsi*4 + {s}]")
            o.append(f"  bextr esi, {x}, eax")
        o.append(f"  add edx, dword ptr [rdi + rsi*4 + {s + 1024}]")
        o.append(f"  bextr esi, {x}, ecx")
        o.append(f"  xor edx, dword ptr [rdi + rsi*4 + {s + 2048}]")
        o.append(f"  movzx esi, {LOW[u][hx]}")
        o.append(f"  add edx, dword ptr [rdi + rsi*4 + {s + 3072}]")
        o.append(f"  xor {y}, edx")
    else:
        x = slot(u, hx)
        o.append(f"  movzx esi, byte ptr [rsp + {x + 3}]")
        o.append(f"  mov edx, dword ptr [rdi + rsi*4 + {s}]")
        o.append(f"  movzx esi, byte ptr [rsp + {x + 2}]")
        o.append(f"  add edx, dword ptr [rdi + rsi*4 + {s + 1024}]")
        o.append(f"  movzx esi, byte ptr [rsp + {x + 1}]")
        o.append(f"  xor edx, dword ptr [rdi + rsi*4 + {s + 2048}]")
        o.append(f"  movzx esi, byte ptr [rsp + {x}]")
        o.append(f"  add edx, dword ptr [rdi + rsi*4 + {s + 3072}]")
        o.append(f"  xor edx, dword ptr [rdi + {base + 4 * r}]")
        o.append(f"  xor dword ptr [rsp + {slot(u, hy)}], edx")


def function(o, style, n):
    mem = max(0, n - REG_LANES)
    # the counter plus the stack lanes, keeping rsp 16-byte aligned after the six pushes
    frame = 8 + 8 * mem + (8 if mem % 2 == 0 else 0)
    f = f"bc_expand0_{style}_{n}"
    o += [f"  .globl {f}", f"  .type {f}, @function", "  .p2align 6", f"{f}:"]
    for r in ["rbx", "rbp", "r12", "r13", "r14", "r15"]:
        o.append(f"  push {r}")
    o += [f"  sub rsp, {frame}", "  mov ecx, 0x0808"]
    if style == "bextr":
        o.append("  mov eax, 0x0810")
    o.append("  mov qword ptr [rsp], 0")
    for u in range(n):
        if u < REG_LANES:
            o += [f"  xor {HALVES[u][0]}, {HALVES[u][0]}", f"  xor {HALVES[u][1]}, {HALVES[u][1]}"]
        else:
            o.append(f"  mov qword ptr [rsp + {slot(u, 0)}], 0")
    o += ["  .p2align 4", f".Lenc_{style}_{n}:"]
    for u in range(n):
        if u < REG_LANES:
            o.append(f"  xor {HALVES[u][0]}, dword ptr [rdi + {u * STRIDE}]")
        else:
            o += [f"  mov edx, dword ptr [rdi + {u * STRIDE}]", f"  xor dword ptr [rsp + {slot(u, 0)}], edx"]
    for r in range(1, 17, 2):
        for u in range(n):
            half_round(o, style, u, 0, r)
        for u in range(n):
            half_round(o, style, u, 1, r + 1)
    # the output block (R ^ P[17], L) goes to words 2j, 2j+1 and is the next input: store it, then swap the halves
    o.append("  mov rsi, qword ptr [rsp]")
    for u in range(n):
        base = u * STRIDE
        if u < REG_LANES:
            l, rr = HALVES[u]
            o += [f"  xor {rr}, dword ptr [rdi + {base + 68}]",
                  f"  mov dword ptr [rdi + rsi*8 + {base}], {rr}",
                  f"  mov dword ptr [rdi + rsi*8 + {base + 4}], {l}",
                  f"  mov edx, {l}", f"  mov {l}, {rr}", f"  mov {rr}, edx"]
        else:
            o += [f"  mov edx, dword ptr [rsp + {slot(u, 1)}]",
                  f"  xor edx, dword ptr [rdi + {base + 68}]",
                  f"  mov eax, dword ptr [rsp + {slot(u, 0)}]",
                  f"  mov dword ptr [rdi + rsi*8 + {base}], edx",
                  f"  mov dword ptr [rdi + rsi*8 + {base + 4}], eax",
                  f"  mov dword ptr [rsp + {slot(u, 0)}], edx",
                  f"  mov dword ptr [rsp + {slot(u, 1)}], eax"]
    # the stack lanes' swap used eax
    if style == "bextr" and mem > 0:
        o.append("  mov eax, 0x0810")
    o += ["  add rsi, 1", "  mov qword ptr [rsp], rsi", f"  cmp rsi, {ENCRYPTIONS}", f"  jb .Lenc_{style}_{n}",
          f"  add rsp, {frame}"]
    for r in ["r15", "r14", "r13", "r12", "rbp", "rbx"]:
        o.append(f"  pop {r}")
    o += ["  ret", f"  .size {f}, .-{f}", ""]


def gen_asm():
    o = ["// GENERATED by tools/gen-bcrypt-native.py: do not edit.", "#if defined(__x86_64__) && defined(__linux__)",
         "  .intel_syntax noprefix", "  .text", ""]
    for style in ("ah", "bextr"):
        for n in range(1, MAX_ASM + 1):
            function(o, style, n)
    o += ['  .section .note.GNU-stack,"",@progbits', "#endif"]
    return o


def c_f(k, x):
    s = (k * WORDS + 18)
    return (f"(((a[{s} + ({x} >> 24)] + a[{s + 256} + ({x} >> 16 & 0xff)]) ^ a[{s + 512} + ({x} >> 8 & 0xff)]) "
            f"+ a[{s + 768} + ({x} & 0xff)])")


def gen_c():
    o = ["// GENERATED by tools/gen-bcrypt-native.py: do not edit.", "#include <stdint.h>", ""]
    for n in range(1, MAX_C + 1):
        o.append(f"static void bc_expand0_c_{n}(uint32_t *restrict a) {{")
        o.append("  uint32_t " + ", ".join(f"l{k} = 0, r{k} = 0" for k in range(n)) + ", t;")
        o.append(f"  for (uint32_t i = 0; i < {WORDS}; i += 2) {{")
        for k in range(n):
            o.append(f"    l{k} ^= a[{k * WORDS}];")
        for r in range(1, 17, 2):
            for k in range(n):
                o.append(f"    r{k} ^= {c_f(k, f'l{k}')} ^ a[{k * WORDS + r}];")
            for k in range(n):
                o.append(f"    l{k} ^= {c_f(k, f'r{k}')} ^ a[{k * WORDS + r + 1}];")
        for k in range(n):
            o.append(f"    r{k} ^= a[{k * WORDS + 17}]; t = l{k}; l{k} = r{k}; r{k} = t;")
            o.append(f"    a[{k * WORDS} + i] = l{k}; a[{k * WORDS} + i + 1] = r{k};")
        o += ["  }", "}", ""]
    return o


sys.stdout.write("\n".join({"asm": gen_asm, "c": gen_c}[sys.argv[1]]()) + "\n")
