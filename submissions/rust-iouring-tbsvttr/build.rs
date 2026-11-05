use std::fmt::Write;
use std::path::PathBuf;

const MAX_LANES: usize = 6;
const DATA_WORDS: usize = 18 + 4 * 256;
const STATE_WORDS: usize = DATA_WORDS + 14;
const STRIDE: usize = STATE_WORDS * 4;
const ENCRYPTIONS: usize = DATA_WORDS / 2;

const HALVES: [[&str; 2]; MAX_LANES] = [
    ["ebx", "ebp"],
    ["r8d", "r9d"],
    ["r10d", "r11d"],
    ["r12d", "r13d"],
    ["r14d", "r15d"],
    ["eax", "ecx"],
];

const LOW_BYTES: [[&str; 2]; MAX_LANES] = [
    ["bl", "bpl"],
    ["r8b", "r9b"],
    ["r10b", "r11b"],
    ["r12b", "r13b"],
    ["r14b", "r15b"],
    ["al", "cl"],
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum ExtractStyle {
    Ah,
    Bextr,
    Shrx,
}

impl ExtractStyle {
    fn tag(self) -> &'static str {
        match self {
            ExtractStyle::Ah => "ah",
            ExtractStyle::Bextr => "bextr",
            ExtractStyle::Shrx => "shrx",
        }
    }

    fn reg_lanes(self) -> usize {
        match self {
            ExtractStyle::Shrx => 6,
            ExtractStyle::Ah | ExtractStyle::Bextr => 5,
        }
    }
}

fn stack_slot(reg_lanes: usize, lane: usize, half: usize) -> usize {
    8 + 8 * (lane - reg_lanes) + 4 * half
}

fn emit_half_round(out: &mut String, style: ExtractStyle, lane: usize, hx: usize, round: usize) {
    let reg_lanes = style.reg_lanes();
    let base = lane * STRIDE;
    let sbox = base + 72;
    let hy = 1 - hx;
    if lane < reg_lanes {
        let x = HALVES[lane][hx];
        let y = HALVES[lane][hy];
        let _ = writeln!(out, "  xor {y}, dword ptr [rdi + {}]", base + 4 * round);
        match style {
            ExtractStyle::Ah => {
                let _ = writeln!(out, "  rorx eax, {x}, 16");
                let _ = writeln!(out, "  movzx esi, ah");
                let _ = writeln!(out, "  mov edx, dword ptr [rdi + rsi*4 + {sbox}]");
                let _ = writeln!(out, "  movzx esi, al");
                let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 1024);
                let _ = writeln!(out, "  bextr esi, {x}, ecx");
                let _ = writeln!(out, "  xor edx, dword ptr [rdi + rsi*4 + {}]", sbox + 2048);
            }
            ExtractStyle::Bextr => {
                let _ = writeln!(out, "  mov esi, {x}");
                let _ = writeln!(out, "  shr esi, 24");
                let _ = writeln!(out, "  mov edx, dword ptr [rdi + rsi*4 + {sbox}]");
                let _ = writeln!(out, "  bextr esi, {x}, eax");
                let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 1024);
                let _ = writeln!(out, "  bextr esi, {x}, ecx");
                let _ = writeln!(out, "  xor edx, dword ptr [rdi + rsi*4 + {}]", sbox + 2048);
            }
            ExtractStyle::Shrx => {
                let _ = writeln!(out, "  mov esi, {x}");
                let _ = writeln!(out, "  shr esi, 24");
                let _ = writeln!(out, "  mov edx, dword ptr [rdi + rsi*4 + {sbox}]");
                let _ = writeln!(out, "  rorx esi, {x}, 16");
                let _ = writeln!(out, "  movzx esi, sil");
                let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 1024);
                let _ = writeln!(out, "  rorx esi, {x}, 8");
                let _ = writeln!(out, "  movzx esi, sil");
                let _ = writeln!(out, "  xor edx, dword ptr [rdi + rsi*4 + {}]", sbox + 2048);
            }
        }
        let _ = writeln!(out, "  movzx esi, {}", LOW_BYTES[lane][hx]);
        let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 3072);
        let _ = writeln!(out, "  xor {y}, edx");
    } else {
        let x_off = stack_slot(reg_lanes, lane, hx);
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {}]", x_off + 3);
        let _ = writeln!(out, "  mov edx, dword ptr [rdi + rsi*4 + {sbox}]");
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {}]", x_off + 2);
        let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 1024);
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {}]", x_off + 1);
        let _ = writeln!(out, "  xor edx, dword ptr [rdi + rsi*4 + {}]", sbox + 2048);
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {x_off}]");
        let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 3072);
        let _ = writeln!(out, "  xor edx, dword ptr [rdi + {}]", base + 4 * round);
        let _ = writeln!(
            out,
            "  xor dword ptr [rsp + {}], edx",
            stack_slot(reg_lanes, lane, hy)
        );
    }
}

fn emit_style_constants(out: &mut String, style: ExtractStyle) {
    match style {
        ExtractStyle::Ah => {
            let _ = writeln!(out, "  mov ecx, 0x0808");
        }
        ExtractStyle::Bextr => {
            let _ = writeln!(out, "  mov ecx, 0x0808");
            let _ = writeln!(out, "  mov eax, 0x0810");
        }
        ExtractStyle::Shrx => {}
    }
}

fn emit_restore_eax(out: &mut String, style: ExtractStyle, mem_lanes: usize) {
    if mem_lanes > 0 && style == ExtractStyle::Bextr {
        let _ = writeln!(out, "  mov eax, 0x0810");
    }
}

fn emit_xor_p_simd(out: &mut String, lanes: usize, ptr_reg: &str) {
    for u in 0..lanes {
        let st_off = u * STRIDE;
        let p_off = u * 72;
        for chunk in 0..4 {
            let boff = chunk * 16;
            let _ = writeln!(out, "  movdqu xmm0, xmmword ptr [rdi + {}]", st_off + boff);
            let _ = writeln!(out, "  movdqu xmm1, xmmword ptr [{ptr_reg} + {}]", p_off + boff);
            let _ = writeln!(out, "  pxor xmm0, xmm1");
            let _ = writeln!(out, "  movdqu xmmword ptr [rdi + {}], xmm0", st_off + boff);
        }
        let _ = writeln!(out, "  mov rdx, qword ptr [{ptr_reg} + {}]", p_off + 64);
        let _ = writeln!(out, "  xor qword ptr [rdi + {}], rdx", st_off + 64);
    }
}

fn emit_expand_body(
    out: &mut String,
    style: ExtractStyle,
    lanes: usize,
    label_suffix: &str,
    salted_offset: Option<usize>,
) {
    let reg_lanes = style.reg_lanes();
    let mem_lanes = lanes.saturating_sub(reg_lanes);
    let tag = style.tag();
    let lbl = format!(".Lenc_{tag}_{lanes}_{label_suffix}");

    emit_style_constants(out, style);
    let _ = writeln!(out, "  mov qword ptr [rsp], 0");
    for u in 0..lanes {
        if u < reg_lanes {
            let l = HALVES[u][0];
            let r = HALVES[u][1];
            let _ = writeln!(out, "  xor {l}, {l}");
            let _ = writeln!(out, "  xor {r}, {r}");
        } else {
            let _ = writeln!(out, "  mov qword ptr [rsp + {}], 0", stack_slot(reg_lanes, u, 0));
        }
    }
    let _ = writeln!(out, "  .p2align 4");
    let _ = writeln!(out, "{lbl}:");
    if let Some(salt_slot) = salted_offset {
        let _ = writeln!(out, "  mov rsi, qword ptr [rsp]");
        let _ = writeln!(out, "  and esi, 1");
        let _ = writeln!(out, "  mov rdx, qword ptr [rsp + {salt_slot}]");
        for u in 0..lanes {
            let p_off = u * 72;
            if u < reg_lanes {
                let l = HALVES[u][0];
                let r = HALVES[u][1];
                let _ = writeln!(out, "  xor {l}, dword ptr [rdx + rsi*8 + {p_off}]");
                let _ = writeln!(out, "  xor {r}, dword ptr [rdx + rsi*8 + {}]", p_off + 4);
            } else {
                let s0 = stack_slot(reg_lanes, u, 0);
                let s1 = stack_slot(reg_lanes, u, 1);
                let _ = writeln!(out, "  mov eax, dword ptr [rdx + rsi*8 + {p_off}]");
                let _ = writeln!(out, "  xor dword ptr [rsp + {s0}], eax");
                let _ = writeln!(out, "  mov eax, dword ptr [rdx + rsi*8 + {}]", p_off + 4);
                let _ = writeln!(out, "  xor dword ptr [rsp + {s1}], eax");
            }
        }
        emit_restore_eax(out, style, mem_lanes);
    }
    for u in 0..lanes {
        let base = u * STRIDE;
        if u < reg_lanes {
            let _ = writeln!(out, "  xor {}, dword ptr [rdi + {base}]", HALVES[u][0]);
        } else {
            let _ = writeln!(out, "  mov edx, dword ptr [rdi + {base}]");
            let _ = writeln!(out, "  xor dword ptr [rsp + {}], edx", stack_slot(reg_lanes, u, 0));
        }
    }
    let mut r = 1;
    while r < 17 {
        for u in 0..lanes {
            emit_half_round(out, style, u, 0, r);
        }
        for u in 0..lanes {
            emit_half_round(out, style, u, 1, r + 1);
        }
        r += 2;
    }
    let _ = writeln!(out, "  mov rsi, qword ptr [rsp]");
    for u in 0..lanes {
        let base = u * STRIDE;
        if u < reg_lanes {
            let l = HALVES[u][0];
            let rr = HALVES[u][1];
            let _ = writeln!(out, "  xor {rr}, dword ptr [rdi + {}]", base + 68);
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {base}], {rr}");
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {}], {l}", base + 4);
            let _ = writeln!(out, "  mov edx, {l}");
            let _ = writeln!(out, "  mov {l}, {rr}");
            let _ = writeln!(out, "  mov {rr}, edx");
        } else {
            let s0 = stack_slot(reg_lanes, u, 0);
            let s1 = stack_slot(reg_lanes, u, 1);
            let _ = writeln!(out, "  mov edx, dword ptr [rsp + {s1}]");
            let _ = writeln!(out, "  xor edx, dword ptr [rdi + {}]", base + 68);
            let _ = writeln!(out, "  mov eax, dword ptr [rsp + {s0}]");
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {base}], edx");
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {}], eax", base + 4);
            let _ = writeln!(out, "  mov dword ptr [rsp + {s0}], edx");
            let _ = writeln!(out, "  mov dword ptr [rsp + {s1}], eax");
        }
    }
    emit_restore_eax(out, style, mem_lanes);
    let _ = writeln!(out, "  add rsi, 1");
    let _ = writeln!(out, "  mov qword ptr [rsp], rsi");
    let _ = writeln!(out, "  cmp rsi, {ENCRYPTIONS}");
    let _ = writeln!(out, "  jb {lbl}");
}

fn emit_cost10_kernel(out: &mut String, style: ExtractStyle, lanes: usize) {
    let reg_lanes = style.reg_lanes();
    let mem_lanes = lanes.saturating_sub(reg_lanes);
    let meta_off = 8 + 8 * mem_lanes;
    let raw_frame = meta_off + 40;
    let frame = if raw_frame % 16 == 0 { raw_frame + 8 } else { raw_frame };

    let tag = style.tag();
    let sym = format!("bc_cost10_{tag}_{lanes}");

    let _ = writeln!(out, "  .globl {sym}");
    let _ = writeln!(out, "  .type {sym}, @function");
    let _ = writeln!(out, "  .p2align 6");
    let _ = writeln!(out, "{sym}:");
    for reg in ["rbx", "rbp", "r12", "r13", "r14", "r15"] {
        let _ = writeln!(out, "  push {reg}");
    }
    let _ = writeln!(out, "  sub rsp, {frame}");
    let _ = writeln!(out, "  mov qword ptr [rsp + {}], rsi", meta_off);
    let _ = writeln!(out, "  mov qword ptr [rsp + {}], rdx", meta_off + 8);
    let _ = writeln!(out, "  mov qword ptr [rsp + {}], rcx", meta_off + 16);
    let _ = writeln!(out, "  mov qword ptr [rsp + {}], r8", meta_off + 24);

    // Initial salted key expansion
    let _ = writeln!(out, "  mov rsi, qword ptr [rsp + {}]", meta_off);
    emit_xor_p_simd(out, lanes, "rsi");
    emit_expand_body(out, style, lanes, "init", Some(meta_off + 8));

    // 2^cost key/salt expansion loop
    let _ = writeln!(out, "  .p2align 4");
    let _ = writeln!(out, ".Lround_{tag}_{lanes}:");
    let _ = writeln!(out, "  mov rsi, qword ptr [rsp + {}]", meta_off);
    emit_xor_p_simd(out, lanes, "rsi");
    emit_expand_body(out, style, lanes, "key", None);

    let _ = writeln!(out, "  mov rsi, qword ptr [rsp + {}]", meta_off + 8);
    emit_xor_p_simd(out, lanes, "rsi");
    emit_expand_body(out, style, lanes, "salt", None);

    let _ = writeln!(out, "  sub qword ptr [rsp + {}], 1", meta_off + 16);
    let _ = writeln!(out, "  jnz .Lround_{tag}_{lanes}");

    // Final 64-iteration ECB encryption of the 3 OrpheanBeholderScryDoubt 64-bit blocks
    let _ = writeln!(out, "  mov qword ptr [rsp + {}], 0", meta_off + 32);
    let _ = writeln!(out, "  .p2align 4");
    let _ = writeln!(out, ".Lblk_{tag}_{lanes}:");
    let _ = writeln!(out, "  mov rsi, qword ptr [rsp + {}]", meta_off + 24);
    let _ = writeln!(out, "  mov rdx, qword ptr [rsp + {}]", meta_off + 32);
    for u in 0..lanes {
        let c_off = u * 24;
        if u < reg_lanes {
            let l = HALVES[u][0];
            let r = HALVES[u][1];
            let _ = writeln!(out, "  mov {l}, dword ptr [rsi + rdx*8 + {c_off}]");
            let _ = writeln!(out, "  mov {r}, dword ptr [rsi + rdx*8 + {}]", c_off + 4);
        } else {
            let s0 = stack_slot(reg_lanes, u, 0);
            let s1 = stack_slot(reg_lanes, u, 1);
            let _ = writeln!(out, "  mov eax, dword ptr [rsi + rdx*8 + {c_off}]");
            let _ = writeln!(out, "  mov ecx, dword ptr [rsi + rdx*8 + {}]", c_off + 4);
            let _ = writeln!(out, "  mov dword ptr [rsp + {s0}], eax");
            let _ = writeln!(out, "  mov dword ptr [rsp + {s1}], ecx");
        }
    }

    emit_style_constants(out, style);
    let _ = writeln!(out, "  mov qword ptr [rsp], 64");
    let _ = writeln!(out, "  .p2align 4");
    let _ = writeln!(out, ".Lfin64_{tag}_{lanes}:");
    for u in 0..lanes {
        let base = u * STRIDE;
        if u < reg_lanes {
            let _ = writeln!(out, "  xor {}, dword ptr [rdi + {base}]", HALVES[u][0]);
        } else {
            let _ = writeln!(out, "  mov edx, dword ptr [rdi + {base}]");
            let _ = writeln!(out, "  xor dword ptr [rsp + {}], edx", stack_slot(reg_lanes, u, 0));
        }
    }
    let mut r = 1;
    while r < 17 {
        for u in 0..lanes {
            emit_half_round(out, style, u, 0, r);
        }
        for u in 0..lanes {
            emit_half_round(out, style, u, 1, r + 1);
        }
        r += 2;
    }
    for u in 0..lanes {
        let base = u * STRIDE;
        if u < reg_lanes {
            let l = HALVES[u][0];
            let rr = HALVES[u][1];
            let _ = writeln!(out, "  xor {rr}, dword ptr [rdi + {}]", base + 68);
            let _ = writeln!(out, "  mov edx, {l}");
            let _ = writeln!(out, "  mov {l}, {rr}");
            let _ = writeln!(out, "  mov {rr}, edx");
        } else {
            let s0 = stack_slot(reg_lanes, u, 0);
            let s1 = stack_slot(reg_lanes, u, 1);
            let _ = writeln!(out, "  mov edx, dword ptr [rsp + {s1}]");
            let _ = writeln!(out, "  xor edx, dword ptr [rdi + {}]", base + 68);
            let _ = writeln!(out, "  mov eax, dword ptr [rsp + {s0}]");
            let _ = writeln!(out, "  mov dword ptr [rsp + {s0}], edx");
            let _ = writeln!(out, "  mov dword ptr [rsp + {s1}], eax");
        }
    }
    emit_restore_eax(out, style, mem_lanes);
    let _ = writeln!(out, "  sub qword ptr [rsp], 1");
    let _ = writeln!(out, "  jnz .Lfin64_{tag}_{lanes}");

    let _ = writeln!(out, "  mov rsi, qword ptr [rsp + {}]", meta_off + 24);
    let _ = writeln!(out, "  mov rdx, qword ptr [rsp + {}]", meta_off + 32);
    for u in 0..lanes {
        let c_off = u * 24;
        if u < reg_lanes {
            let l = HALVES[u][0];
            let r = HALVES[u][1];
            let _ = writeln!(out, "  mov dword ptr [rsi + rdx*8 + {c_off}], {l}");
            let _ = writeln!(out, "  mov dword ptr [rsi + rdx*8 + {}], {r}", c_off + 4);
        } else {
            let s0 = stack_slot(reg_lanes, u, 0);
            let s1 = stack_slot(reg_lanes, u, 1);
            let _ = writeln!(out, "  mov eax, dword ptr [rsp + {s0}]");
            let _ = writeln!(out, "  mov ecx, dword ptr [rsp + {s1}]");
            let _ = writeln!(out, "  mov dword ptr [rsi + rdx*8 + {c_off}], eax");
            let _ = writeln!(out, "  mov dword ptr [rsi + rdx*8 + {}], ecx", c_off + 4);
        }
    }
    let _ = writeln!(out, "  add rdx, 1");
    let _ = writeln!(out, "  mov qword ptr [rsp + {}], rdx", meta_off + 32);
    let _ = writeln!(out, "  cmp rdx, 3");
    let _ = writeln!(out, "  jb .Lblk_{tag}_{lanes}");

    let _ = writeln!(out, "  add rsp, {frame}");
    for reg in ["r15", "r14", "r13", "r12", "rbp", "rbx"] {
        let _ = writeln!(out, "  pop {reg}");
    }
    let _ = writeln!(out, "  ret");
    let _ = writeln!(out, "  .size {sym}, .-{sym}");
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let mut asm = String::with_capacity(640 * 1024);
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64") {
        let _ = writeln!(&mut asm, "  .text");
        for style in [ExtractStyle::Ah, ExtractStyle::Bextr, ExtractStyle::Shrx] {
            for lanes in 1..=MAX_LANES {
                emit_cost10_kernel(&mut asm, style, lanes);
            }
        }
    }
    std::fs::write(out_dir.join("bc_expand0.s"), asm).expect("failed to write bc_expand0.s");
}

