//! CPUID: the x86-64-v3 check the kernel object needs, and the brand string for bench output.
pub const Features = struct { v3: bool };

const Regs = struct { a: u32, b: u32, c: u32, d: u32 };

fn cpuid(leaf: u32, sub: u32) Regs {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .a = a, .b = b, .c = c, .d = d };
}

fn xgetbv0() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("xgetbv"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [c] "{ecx}" (@as(u32, 0)),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn bit(x: u32, n: u5) bool {
    return (x >> n) & 1 == 1;
}

pub fn detect() Features {
    if (cpuid(0, 0).a < 7) return .{ .v3 = false };
    const l1 = cpuid(1, 0);
    if (!bit(l1.c, 27) or !bit(l1.c, 28)) return .{ .v3 = false };
    const ymm = xgetbv0() & 0b110 == 0b110;
    const l7 = cpuid(7, 0);
    const ext = cpuid(0x80000001, 0);
    // AVX2, BMI1, BMI2, FMA, MOVBE, F16C, LZCNT.
    const v3 = ymm and bit(l7.b, 5) and bit(l7.b, 3) and bit(l7.b, 8) and bit(l1.c, 12) and bit(l1.c, 22) and
        bit(l1.c, 29) and bit(ext.c, 5);
    return .{ .v3 = v3 };
}

/// Brand string from leaves 0x80000002..4, trimmed.
pub fn brand(buf: *[48]u8) []const u8 {
    var i: usize = 0;
    for ([_]u32{ 0x80000002, 0x80000003, 0x80000004 }) |leaf| {
        const r = cpuid(leaf, 0);
        for ([_]u32{ r.a, r.b, r.c, r.d }) |w| {
            for (0..4) |k| {
                buf[i] = @truncate(w >> @intCast(8 * k));
                i += 1;
            }
        }
    }
    var end: usize = 48;
    while (end > 0 and (buf[end - 1] == 0 or buf[end - 1] == ' ')) end -= 1;
    var start: usize = 0;
    while (start < end and buf[start] == ' ') start += 1;
    return buf[start..end];
}
