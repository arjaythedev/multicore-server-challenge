//! Generates the hand-scheduled bcrypt expand0 kernels (x86-64, Intel syntax, BMI1/BMI2): one function per index
//! extraction style and lane count, `extern "C" fn bc_expand0_<style>_<n>(state: *mut u32)`. `state` holds n lanes
//! of 1042 words each (P[18] then S[4][256], stride 4168 bytes) with the key already XORed into P; the function
//! encrypts a zero block and writes its 521 chained outputs over P and S in turn, as Blowfish's expand0state does.
//!
//! A port of nick-potts's asm_gen.zig (zig-iouring-nick-potts). One base register reaches every lane, so each S-box
//! and P read is rdi + index*4 + a constant folded into an add or xor; five lanes keep their halves in registers and
//! further lanes keep them on the stack. Two styles, picked per CPU at startup:
//! - `ah`: byte 0 by movzx from the low byte, byte 1 by bextr, bytes 2 and 3 by one rorx then movzx from al and ah.
//! - `bextr`: byte 3 by a copy and a shift, bytes 2 and 1 by bextr, byte 0 by movzx; no partial register reads.
use std::fmt::Write;

const MAX_LANES: usize = 8;
const WORDS: usize = 18 + 4 * 256;
const STRIDE: usize = WORDS * 4;
const ENCRYPTIONS: usize = WORDS / 2;
const REG_LANES: usize = 5;
const HALVES: [[&str; 2]; REG_LANES] = [["ebx", "ebp"], ["r8d", "r9d"], ["r10d", "r11d"], ["r12d", "r13d"], ["r14d", "r15d"]];
const LOW: [[&str; 2]; REG_LANES] = [["bl", "bpl"], ["r8b", "r9b"], ["r10b", "r11b"], ["r12b", "r13b"], ["r14b", "r15b"]];

#[derive(Clone, Copy, PartialEq)]
enum Style {
    Ah,
    Bextr,
}

fn slot(u: usize, h: usize) -> usize {
    8 + 8 * (u - REG_LANES) + 4 * h
}

/// y ^= P[r] ^ F(x) for lane u, where x is half `hx` and y the other.
fn half_round(o: &mut String, style: Style, u: usize, hx: usize, r: usize) {
    let base = u * STRIDE;
    let s = base + 72;
    let hy = 1 - hx;
    if u < REG_LANES {
        let (x, y) = (HALVES[u][hx], HALVES[u][hy]);
        writeln!(o, "  xor {y}, dword ptr [rdi + {}]", base + 4 * r).unwrap();
        match style {
            Style::Ah => {
                writeln!(o, "  rorx eax, {x}, 16").unwrap();
                writeln!(o, "  movzx esi, ah").unwrap();
                writeln!(o, "  mov edx, dword ptr [rdi + rsi*4 + {s}]").unwrap();
                writeln!(o, "  movzx esi, al").unwrap();
            }
            Style::Bextr => {
                writeln!(o, "  mov esi, {x}").unwrap();
                writeln!(o, "  shr esi, 24").unwrap();
                writeln!(o, "  mov edx, dword ptr [rdi + rsi*4 + {s}]").unwrap();
                writeln!(o, "  bextr esi, {x}, eax").unwrap();
            }
        }
        writeln!(o, "  add edx, dword ptr [rdi + rsi*4 + {}]", s + 1024).unwrap();
        writeln!(o, "  bextr esi, {x}, ecx").unwrap();
        writeln!(o, "  xor edx, dword ptr [rdi + rsi*4 + {}]", s + 2048).unwrap();
        writeln!(o, "  movzx esi, {}", LOW[u][hx]).unwrap();
        writeln!(o, "  add edx, dword ptr [rdi + rsi*4 + {}]", s + 3072).unwrap();
        writeln!(o, "  xor {y}, edx").unwrap();
    } else {
        let x = slot(u, hx);
        writeln!(o, "  movzx esi, byte ptr [rsp + {}]", x + 3).unwrap();
        writeln!(o, "  mov edx, dword ptr [rdi + rsi*4 + {s}]").unwrap();
        writeln!(o, "  movzx esi, byte ptr [rsp + {}]", x + 2).unwrap();
        writeln!(o, "  add edx, dword ptr [rdi + rsi*4 + {}]", s + 1024).unwrap();
        writeln!(o, "  movzx esi, byte ptr [rsp + {}]", x + 1).unwrap();
        writeln!(o, "  xor edx, dword ptr [rdi + rsi*4 + {}]", s + 2048).unwrap();
        writeln!(o, "  movzx esi, byte ptr [rsp + {x}]").unwrap();
        writeln!(o, "  add edx, dword ptr [rdi + rsi*4 + {}]", s + 3072).unwrap();
        writeln!(o, "  xor edx, dword ptr [rdi + {}]", base + 4 * r).unwrap();
        writeln!(o, "  xor dword ptr [rsp + {}], edx", slot(u, hy)).unwrap();
    }
}

fn function(o: &mut String, style: Style, n: usize) {
    let mem_lanes = n.saturating_sub(REG_LANES);
    // Counter plus the stack lanes, keeping rsp 16-byte aligned after the six pushes.
    let frame = 8 + 8 * mem_lanes + if mem_lanes % 2 == 0 { 8 } else { 0 };
    let name = if style == Style::Ah { "ah" } else { "bextr" };
    let f = format!("bc_expand0_{name}_{n}");
    writeln!(o, "  .globl {f}\n  .type {f}, @function\n  .p2align 6\n{f}:").unwrap();
    for r in ["rbx", "rbp", "r12", "r13", "r14", "r15"] {
        writeln!(o, "  push {r}").unwrap();
    }
    writeln!(o, "  sub rsp, {frame}\n  mov ecx, 0x0808").unwrap();
    if style == Style::Bextr {
        writeln!(o, "  mov eax, 0x0810").unwrap();
    }
    writeln!(o, "  mov qword ptr [rsp], 0").unwrap();
    for u in 0..n {
        if u < REG_LANES {
            writeln!(o, "  xor {0}, {0}\n  xor {1}, {1}", HALVES[u][0], HALVES[u][1]).unwrap();
        } else {
            writeln!(o, "  mov qword ptr [rsp + {}], 0", slot(u, 0)).unwrap();
        }
    }
    writeln!(o, "  .p2align 4\n.Lenc_{name}_{n}:").unwrap();
    for u in 0..n {
        if u < REG_LANES {
            writeln!(o, "  xor {}, dword ptr [rdi + {}]", HALVES[u][0], u * STRIDE).unwrap();
        } else {
            writeln!(o, "  mov edx, dword ptr [rdi + {}]\n  xor dword ptr [rsp + {}], edx", u * STRIDE, slot(u, 0)).unwrap();
        }
    }
    let mut r = 1;
    while r < 17 {
        for u in 0..n {
            half_round(o, style, u, 0, r);
        }
        for u in 0..n {
            half_round(o, style, u, 1, r + 1);
        }
        r += 2;
    }
    // Output block (R ^ P[17], L) goes to words 2j, 2j+1 and is the next input: store it, then swap the halves.
    writeln!(o, "  mov rsi, qword ptr [rsp]").unwrap();
    for u in 0..n {
        let base = u * STRIDE;
        if u < REG_LANES {
            let (l, rr) = (HALVES[u][0], HALVES[u][1]);
            writeln!(o, "  xor {rr}, dword ptr [rdi + {}]", base + 68).unwrap();
            writeln!(o, "  mov dword ptr [rdi + rsi*8 + {base}], {rr}").unwrap();
            writeln!(o, "  mov dword ptr [rdi + rsi*8 + {}], {l}", base + 4).unwrap();
            writeln!(o, "  mov edx, {l}\n  mov {l}, {rr}\n  mov {rr}, edx").unwrap();
        } else {
            writeln!(o, "  mov edx, dword ptr [rsp + {}]", slot(u, 1)).unwrap();
            writeln!(o, "  xor edx, dword ptr [rdi + {}]", base + 68).unwrap();
            writeln!(o, "  mov eax, dword ptr [rsp + {}]", slot(u, 0)).unwrap();
            writeln!(o, "  mov dword ptr [rdi + rsi*8 + {base}], edx").unwrap();
            writeln!(o, "  mov dword ptr [rdi + rsi*8 + {}], eax", base + 4).unwrap();
            writeln!(o, "  mov dword ptr [rsp + {}], edx", slot(u, 0)).unwrap();
            writeln!(o, "  mov dword ptr [rsp + {}], eax", slot(u, 1)).unwrap();
        }
    }
    // The stack lanes' swap used eax.
    if style == Style::Bextr && mem_lanes > 0 {
        writeln!(o, "  mov eax, 0x0810").unwrap();
    }
    writeln!(o, "  add rsi, 1\n  mov qword ptr [rsp], rsi\n  cmp rsi, {ENCRYPTIONS}\n  jb .Lenc_{name}_{n}").unwrap();
    writeln!(o, "  add rsp, {frame}").unwrap();
    for r in ["r15", "r14", "r13", "r12", "rbp", "rbx"] {
        writeln!(o, "  pop {r}").unwrap();
    }
    writeln!(o, "  ret\n  .size {f}, .-{f}").unwrap();
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let mut o = String::new();
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64") {
        for style in [Style::Ah, Style::Bextr] {
            for n in 1..=MAX_LANES {
                function(&mut o, style, n);
            }
        }
    }
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("expand0.s");
    std::fs::write(out, o).unwrap();
}
