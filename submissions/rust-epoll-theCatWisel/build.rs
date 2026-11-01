use std::fmt::Write;
use std::path::PathBuf;

const MAX_LANES: usize = 6;
const DATA_WORDS: usize = 18 + 4 * 256;
const STATE_WORDS: usize = DATA_WORDS + 14;
const STRIDE: usize = STATE_WORDS * 4;
const ENCRYPTIONS: usize = DATA_WORDS / 2;
const REG_LANES: usize = 5;

const HALVES: [[&str; 2]; REG_LANES] = [
    ["ebx", "ebp"],
    ["r8d", "r9d"],
    ["r10d", "r11d"],
    ["r12d", "r13d"],
    ["r14d", "r15d"],
];

const LOW_BYTES: [[&str; 2]; REG_LANES] = [
    ["bl", "bpl"],
    ["r8b", "r9b"],
    ["r10b", "r11b"],
    ["r12b", "r13b"],
    ["r14b", "r15b"],
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
}

fn stack_slot(lane: usize, half: usize) -> usize {
    8 + 8 * (lane - REG_LANES) + 4 * half
}

fn emit_half_round(out: &mut String, style: ExtractStyle, lane: usize, hx: usize, round: usize) {
    let base = lane * STRIDE;
    let sbox = base + 72;
    let hy = 1 - hx;
    if lane < REG_LANES {
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
                let _ = writeln!(out, "  shrx esi, {x}, eax");
                let _ = writeln!(out, "  mov edx, dword ptr [rdi + rsi*4 + {sbox}]");
                let _ = writeln!(out, "  shrx esi, {x}, ecx");
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
        let x_off = stack_slot(lane, hx);
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {}]", x_off + 3);
        let _ = writeln!(out, "  mov edx, dword ptr [rdi + rsi*4 + {sbox}]");
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {}]", x_off + 2);
        let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 1024);
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {}]", x_off + 1);
        let _ = writeln!(out, "  xor edx, dword ptr [rdi + rsi*4 + {}]", sbox + 2048);
        let _ = writeln!(out, "  movzx esi, byte ptr [rsp + {x_off}]");
        let _ = writeln!(out, "  add edx, dword ptr [rdi + rsi*4 + {}]", sbox + 3072);
        let _ = writeln!(out, "  xor edx, dword ptr [rdi + {}]", base + 4 * round);
        let _ = writeln!(out, "  xor dword ptr [rsp + {}], edx", stack_slot(lane, hy));
    }
}

fn emit_kernel(out: &mut String, style: ExtractStyle, lanes: usize) {
    let mem_lanes = lanes.saturating_sub(REG_LANES);
    let frame = 8 + 8 * mem_lanes + if mem_lanes % 2 == 0 { 8 } else { 0 };
    let tag = style.tag();
    let sym = format!("bc_expand0_{tag}_{lanes}");

    let _ = writeln!(out, "  .globl {sym}");
    let _ = writeln!(out, "  .type {sym}, @function");
    let _ = writeln!(out, "  .p2align 6");
    let _ = writeln!(out, "{sym}:");
    for reg in ["rbx", "rbp", "r12", "r13", "r14", "r15"] {
        let _ = writeln!(out, "  push {reg}");
    }
    let _ = writeln!(out, "  sub rsp, {frame}");
    match style {
        ExtractStyle::Ah => {
            let _ = writeln!(out, "  mov ecx, 0x0808");
        }
        ExtractStyle::Bextr => {
            let _ = writeln!(out, "  mov ecx, 0x0808");
            let _ = writeln!(out, "  mov eax, 0x0810");
        }
        ExtractStyle::Shrx => {
            let _ = writeln!(out, "  mov ecx, 16");
            let _ = writeln!(out, "  mov eax, 24");
        }
    }
    let _ = writeln!(out, "  mov qword ptr [rsp], 0");
    for u in 0..lanes {
        if u < REG_LANES {
            let l = HALVES[u][0];
            let r = HALVES[u][1];
            let _ = writeln!(out, "  xor {l}, {l}");
            let _ = writeln!(out, "  xor {r}, {r}");
        } else {
            let _ = writeln!(out, "  mov qword ptr [rsp + {}], 0", stack_slot(u, 0));
        }
    }
    let _ = writeln!(out, "  .p2align 4");
    let _ = writeln!(out, ".Lenc_{tag}_{lanes}:");
    for u in 0..lanes {
        let base = u * STRIDE;
        if u < REG_LANES {
            let _ = writeln!(out, "  xor {}, dword ptr [rdi + {base}]", HALVES[u][0]);
        } else {
            let _ = writeln!(out, "  mov edx, dword ptr [rdi + {base}]");
            let _ = writeln!(out, "  xor dword ptr [rsp + {}], edx", stack_slot(u, 0));
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
        if u < REG_LANES {
            let l = HALVES[u][0];
            let rr = HALVES[u][1];
            let _ = writeln!(out, "  xor {rr}, dword ptr [rdi + {}]", base + 68);
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {base}], {rr}");
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {}], {l}", base + 4);
            let _ = writeln!(out, "  mov edx, {l}");
            let _ = writeln!(out, "  mov {l}, {rr}");
            let _ = writeln!(out, "  mov {rr}, edx");
        } else {
            let s0 = stack_slot(u, 0);
            let s1 = stack_slot(u, 1);
            let _ = writeln!(out, "  mov edx, dword ptr [rsp + {s1}]");
            let _ = writeln!(out, "  xor edx, dword ptr [rdi + {}]", base + 68);
            let _ = writeln!(out, "  mov eax, dword ptr [rsp + {s0}]");
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {base}], edx");
            let _ = writeln!(out, "  mov dword ptr [rdi + rsi*8 + {}], eax", base + 4);
            let _ = writeln!(out, "  mov dword ptr [rsp + {s0}], edx");
            let _ = writeln!(out, "  mov dword ptr [rsp + {s1}], eax");
        }
    }
    if mem_lanes > 0 {
        match style {
            ExtractStyle::Bextr => {
                let _ = writeln!(out, "  mov eax, 0x0810");
            }
            ExtractStyle::Shrx => {
                let _ = writeln!(out, "  mov eax, 24");
            }
            ExtractStyle::Ah => {}
        }
    }
    let _ = writeln!(out, "  add rsi, 1");
    let _ = writeln!(out, "  mov qword ptr [rsp], rsi");
    let _ = writeln!(out, "  cmp rsi, {ENCRYPTIONS}");
    let _ = writeln!(out, "  jb .Lenc_{tag}_{lanes}");
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
    let mut asm = String::with_capacity(384 * 1024);
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64") {
        let _ = writeln!(&mut asm, "  .text");
        for style in [ExtractStyle::Ah, ExtractStyle::Bextr, ExtractStyle::Shrx] {
            for lanes in 1..=MAX_LANES {
                emit_kernel(&mut asm, style, lanes);
            }
        }
    }
    std::fs::write(out_dir.join("bc_expand0.s"), asm).expect("failed to write bc_expand0.s");
}
