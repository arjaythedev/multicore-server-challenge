#!/usr/bin/env python3
"""Writes the x86-64 bcrypt expansion kernels for 1 to 6 hashes in lockstep, as GNU assembler source, to stdout.
native/build.sh runs it and assembles the result into libcbcrypt.so, next to cbcrypt.c.

Each kernel bcrypt_expand_<style>_<n>(uint32_t *a) takes n contiguous lanes of 1042 words (P[18], then S[4][256];
stride 4168 bytes) with the key or salt already XORed into P, encrypts a zero block and writes its 521 chained
outputs over P and S in turn. cbcrypt.c runs the cost loop over them; src/Engine/Bcrypt.fs picks the style and
width that hash fastest on the box.

One base register (rdi) reaches every lane; five lanes keep their halves in registers, a sixth on the stack. The
styles differ in how a round takes the four S-box index bytes apart (all need BMI1 and BMI2):
  ah:    byte 3 and 2 by one RORX then movzx from ah and al, byte 1 by BEXTR, byte 0 by movzx
  bextr: byte 3 by a copy and a shift, bytes 2 and 1 by BEXTR, byte 0 by movzx; no partial-register reads
  shrx:  byte 3 by SHRX, bytes 2 and 1 by one RORX then movzx from ah and al, byte 0 by movzx; no BEXTR

This file is java-servlet-clickin's tools/gen-bcrypt-x86.py (#217), unchanged below this comment but for the
generated file's first line. That is a port of zig-iouring-nick-potts's asm_gen.zig (#117, #168), by way of
rust-epoll-WorriedArrow's build.rs and java-raw-stohirov's gen-bcrypt-native.py (#185). MIT, like the rest of the
repository.
"""
import sys

MAX_LANES = 6
WORDS = 18 + 4 * 256
STRIDE = WORDS * 4
ENCRYPTIONS = WORDS // 2
REG_LANES = 5
HALVES = [["ebx", "ebp"], ["r8d", "r9d"], ["r10d", "r11d"], ["r12d", "r13d"], ["r14d", "r15d"]]
LOW = [["bl", "bpl"], ["r8b", "r9b"], ["r10b", "r11b"], ["r12b", "r13b"], ["r14b", "r15b"]]
STYLES = ("ah", "bextr", "shrx")


def slot(u, h):
    """Stack slot of lane u's half h (0 = L, 1 = R), after the 8-byte encryption counter."""
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
        elif style == "bextr":
            o.append(f"  mov esi, {x}")
            o.append("  shr esi, 24")
            o.append(f"  mov edx, dword ptr [rdi + rsi*4 + {s}]")
            o.append(f"  bextr esi, {x}, eax")
        else:
            o.append(f"  shrx esi, {x}, ecx")
            o.append(f"  mov edx, dword ptr [rdi + rsi*4 + {s}]")
            o.append(f"  rorx eax, {x}, 8")
            o.append("  movzx esi, ah")
        o.append(f"  add edx, dword ptr [rdi + rsi*4 + {s + 1024}]")
        if style == "shrx":
            o.append("  movzx esi, al")
        else:
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
    f = f"bcrypt_expand_{style}_{n}"
    o += [f"  .globl {f}", f"  .hidden {f}", f"  .type {f}, @function", "  .p2align 6", f"{f}:"]
    for r in ["rbx", "rbp", "r12", "r13", "r14", "r15"]:
        o.append(f"  push {r}")
    o += [f"  sub rsp, {frame}", "  mov ecx, " + ("24" if style == "shrx" else "0x0808")]
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
    # the stack lane's swap used eax, which holds bextr's second control
    if style == "bextr" and mem > 0:
        o.append("  mov eax, 0x0810")
    o += ["  add rsi, 1", "  mov qword ptr [rsp], rsi", f"  cmp rsi, {ENCRYPTIONS}", f"  jb .Lenc_{style}_{n}",
          f"  add rsp, {frame}"]
    for r in ["r15", "r14", "r13", "r12", "rbp", "rbx"]:
        o.append(f"  pop {r}")
    o += ["  ret", f"  .size {f}, .-{f}", ""]


def main():
    o = ["// GENERATED by native/gen-bcrypt-x86.py: do not edit.", "#if defined(__x86_64__) && defined(__linux__)",
         "  .intel_syntax noprefix", "  .text", ""]
    for style in STYLES:
        for n in range(1, MAX_LANES + 1):
            function(o, style, n)
    o += ['  .section .note.GNU-stack,"",@progbits', "#endif"]
    sys.stdout.write("\n".join(o) + "\n")


main()
