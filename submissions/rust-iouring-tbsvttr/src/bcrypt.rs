#![allow(dead_code)]

use crate::blowfish::{BF_P, BF_S};
use crate::sys::clock_us;

pub const BCRYPT_LANES: usize = 6;

const BCRYPT_B64: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

const BCRYPT_DEC: [i8; 256] = [
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,
    54, 55, 56, 57, 58, 59, 60, 61, 62, 63, -1, -1, -1, -1, -1, -1,
    -1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, -1, -1, -1, -1, -1,
    -1, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
    43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
];

const BCRYPT_CTEXT: [u32; 6] = [
    0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274,
];

#[derive(Clone, Copy)]
pub struct BcryptJob {
    pub cost: u32,
    pub salt: [u8; 16],
    pub password: [u8; 72],
    pub password_len: usize,
    pub digest: [u8; 23],
}

impl Default for BcryptJob {
    fn default() -> Self {
        Self {
            cost: 10,
            salt: [0u8; 16],
            password: [0u8; 72],
            password_len: 0,
            digest: [0u8; 23],
        }
    }
}

pub fn encode_b64(src: &[u8], out: &mut [u8]) {
    let n = src.len();
    let mut i = 0usize;
    let mut j = 0usize;
    while i < n {
        let b0 = src[i] as u32;
        out[j] = BCRYPT_B64[(b0 >> 2) as usize];
        j += 1;
        if i + 1 >= n {
            out[j] = BCRYPT_B64[((b0 & 0x03) << 4) as usize];
            break;
        }
        let b1 = src[i + 1] as u32;
        out[j] = BCRYPT_B64[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize];
        j += 1;
        if i + 2 >= n {
            out[j] = BCRYPT_B64[((b1 & 0x0f) << 2) as usize];
            break;
        }
        let b2 = src[i + 2] as u32;
        out[j] = BCRYPT_B64[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize];
        out[j + 1] = BCRYPT_B64[(b2 & 0x3f) as usize];
        j += 2;
        i += 3;
    }
}

pub fn decode_b64(src: &[u8], out: &mut [u8]) -> bool {
    let n = out.len();
    let mut i = 0usize;
    let mut j = 0usize;
    while j < n {
        let c0 = BCRYPT_DEC[src[i] as usize];
        let c1 = BCRYPT_DEC[src[i + 1] as usize];
        if c0 < 0 || c1 < 0 {
            return false;
        }
        out[j] = (((c0 as u32) << 2) | ((c1 as u32) >> 4)) as u8;
        j += 1;
        if j >= n {
            break;
        }
        let c2 = BCRYPT_DEC[src[i + 2] as usize];
        if c2 < 0 {
            return false;
        }
        out[j] = ((((c1 as u32) & 0x0f) << 4) | ((c2 as u32) >> 2)) as u8;
        j += 1;
        if j >= n {
            break;
        }
        let c3 = BCRYPT_DEC[src[i + 3] as usize];
        if c3 < 0 {
            return false;
        }
        out[j] = ((((c2 as u32) & 0x03) << 6) | (c3 as u32)) as u8;
        j += 1;
        i += 4;
    }
    true
}

pub fn parse(hash: &[u8], job: &mut BcryptJob, want: &mut [u8; 23]) -> bool {
    if hash.len() != 60
        || hash[0] != b'$'
        || hash[1] != b'2'
        || !matches!(hash[2], b'a' | b'b' | b'y')
        || hash[3] != b'$'
        || !hash[4].is_ascii_digit()
        || !hash[5].is_ascii_digit()
        || hash[6] != b'$'
    {
        return false;
    }
    let cost = ((hash[4] - b'0') as u32) * 10 + ((hash[5] - b'0') as u32);
    if !(4..=31).contains(&cost) {
        return false;
    }
    job.cost = cost;
    decode_b64(&hash[7..29], &mut job.salt) && decode_b64(&hash[29..60], want)
}

pub fn format(job: &BcryptJob, out: &mut [u8; 60]) {
    out[0] = b'$';
    out[1] = b'2';
    out[2] = b'b';
    out[3] = b'$';
    out[4] = b'0' + ((job.cost / 10) as u8);
    out[5] = b'0' + ((job.cost % 10) as u8);
    out[6] = b'$';
    encode_b64(&job.salt, &mut out[7..29]);
    encode_b64(&job.digest, &mut out[29..60]);
}

#[repr(C, align(64))]
#[derive(Clone, Copy)]
struct BfLane {
    s: [u32; 1024],
    p: [u32; 18],
    _pad: [u32; 14],
}

const _: () = assert!(std::mem::size_of::<BfLane>() == 4224);

const INIT_LANE: BfLane = BfLane {
    s: BF_S,
    p: BF_P,
    _pad: [0u32; 14],
};

#[inline(always)]
fn feistel(sk: &[u32; 1024], x: u32) -> u32 {
    unsafe {
        let a = *sk.get_unchecked((x >> 24) as usize);
        let b = *sk.get_unchecked(256 + (((x >> 16) & 0xFF) as usize));
        let c = *sk.get_unchecked(512 + (((x >> 8) & 0xFF) as usize));
        let d = *sk.get_unchecked(768 + ((x & 0xFF) as usize));
        (a.wrapping_add(b) ^ c).wrapping_add(d)
    }
}

#[inline(always)]
fn enc_n<const N: usize>(
    lanes: &[BfLane; BCRYPT_LANES],
    l: &mut [u32; BCRYPT_LANES],
    r: &mut [u32; BCRYPT_LANES],
) {
    for k in 0..N {
        l[k] ^= lanes[k].p[0];
    }
    macro_rules! round_pair {
        ($i1:expr, $i2:expr) => {
            for k in 0..N {
                r[k] ^= feistel(&lanes[k].s, l[k]) ^ lanes[k].p[$i1];
            }
            for k in 0..N {
                l[k] ^= feistel(&lanes[k].s, r[k]) ^ lanes[k].p[$i2];
            }
        };
    }
    round_pair!(1, 2);
    round_pair!(3, 4);
    round_pair!(5, 6);
    round_pair!(7, 8);
    round_pair!(9, 10);
    round_pair!(11, 12);
    round_pair!(13, 14);
    round_pair!(15, 16);
    for k in 0..N {
        let t = l[k];
        l[k] = r[k] ^ lanes[k].p[17];
        r[k] = t;
    }
}

fn expand_0<const N: usize>(
    lanes: &mut [BfLane; BCRYPT_LANES],
    key: &[[u32; 18]; BCRYPT_LANES],
) {
    for k in 0..N {
        for i in 0..18 {
            lanes[k].p[i] ^= key[k][i];
        }
    }
    let mut l = [0u32; BCRYPT_LANES];
    let mut r = [0u32; BCRYPT_LANES];
    let mut i = 0usize;
    while i <= 16 {
        enc_n::<N>(lanes, &mut l, &mut r);
        for k in 0..N {
            lanes[k].p[i] = l[k];
            lanes[k].p[i + 1] = r[k];
        }
        i += 2;
    }
    let mut j = 0usize;
    while j <= 1022 {
        enc_n::<N>(lanes, &mut l, &mut r);
        for k in 0..N {
            lanes[k].s[j] = l[k];
            lanes[k].s[j + 1] = r[k];
        }
        j += 2;
    }
}

fn expand_salt<const N: usize>(
    lanes: &mut [BfLane; BCRYPT_LANES],
    key: &[[u32; 18]; BCRYPT_LANES],
    salt: &[[u32; 4]; BCRYPT_LANES],
) {
    for k in 0..N {
        for i in 0..18 {
            lanes[k].p[i] ^= key[k][i];
        }
    }
    let mut l = [0u32; BCRYPT_LANES];
    let mut r = [0u32; BCRYPT_LANES];
    let mut si = 0usize;
    let mut i = 0usize;
    while i <= 16 {
        for k in 0..N {
            l[k] ^= salt[k][si & 3];
            r[k] ^= salt[k][(si + 1) & 3];
        }
        si += 2;
        enc_n::<N>(lanes, &mut l, &mut r);
        for k in 0..N {
            lanes[k].p[i] = l[k];
            lanes[k].p[i + 1] = r[k];
        }
        i += 2;
    }
    let mut j = 0usize;
    while j <= 1022 {
        for k in 0..N {
            l[k] ^= salt[k][si & 3];
            r[k] ^= salt[k][(si + 1) & 3];
        }
        si += 2;
        enc_n::<N>(lanes, &mut l, &mut r);
        for k in 0..N {
            lanes[k].s[j] = l[k];
            lanes[k].s[j + 1] = r[k];
        }
        j += 2;
    }
}

fn run_n<const N: usize>(jobs: &mut [BcryptJob]) {
    let mut lanes = [INIT_LANE; BCRYPT_LANES];
    let mut pkey = [[0u32; 18]; BCRYPT_LANES];
    let mut skey = [[0u32; 18]; BCRYPT_LANES];
    let mut salt = [[0u32; 4]; BCRYPT_LANES];
    let mut max_rounds = 0u32;

    for k in 0..N {
        let job = &jobs[k];
        let rounds = 1u32 << job.cost;
        if rounds > max_rounds {
            max_rounds = rounds;
        }
        let n = job.password_len.min(72);
        let plen = (n + 1).min(72); // with terminating NUL up to 72 bytes
        let mut pos = 0usize;
        for i in 0..18 {
            let mut w = 0u32;
            for _ in 0..4 {
                let b = if pos < n {
                    job.password[pos] as u32
                } else {
                    0
                };
                w = (w << 8) | b;
                pos += 1;
                if pos >= plen {
                    pos = 0;
                }
            }
            pkey[k][i] = w;
        }
        for i in 0..4 {
            let off = i * 4;
            salt[k][i] = u32::from_be_bytes([
                job.salt[off],
                job.salt[off + 1],
                job.salt[off + 2],
                job.salt[off + 3],
            ]);
        }
        for i in 0..18 {
            skey[k][i] = salt[k][i & 3];
        }
    }

    expand_salt::<N>(&mut lanes, &pkey, &salt);
    for r in 0..max_rounds {
        for k in 0..N {
            if r >= (1u32 << jobs[k].cost) {
                pkey[k].fill(0);
                skey[k].fill(0);
            }
        }
        expand_0::<N>(&mut lanes, &pkey);
        expand_0::<N>(&mut lanes, &skey);
    }

    let mut ctext = [[0u32; 6]; BCRYPT_LANES];
    for k in 0..N {
        ctext[k] = BCRYPT_CTEXT;
    }
    let mut l = [0u32; BCRYPT_LANES];
    let mut r = [0u32; BCRYPT_LANES];
    let mut blk = 0usize;
    while blk <= 4 {
        for k in 0..N {
            l[k] = ctext[k][blk];
            r[k] = ctext[k][blk + 1];
        }
        for _ in 0..64 {
            enc_n::<N>(&lanes, &mut l, &mut r);
        }
        for k in 0..N {
            ctext[k][blk] = l[k];
            ctext[k][blk + 1] = r[k];
        }
        blk += 2;
    }

    for k in 0..N {
        for j in 0..23 {
            let w = ctext[k][j / 4];
            jobs[k].digest[j] = ((w >> (24 - (j & 3) * 8)) & 0xFF) as u8;
        }
    }
}

pub fn run(jobs: &mut [BcryptJob]) {
    match jobs.len() {
        1 => run_n::<1>(jobs),
        2 => run_n::<2>(jobs),
        3 => run_n::<3>(jobs),
        4 => run_n::<4>(jobs),
        5 => run_n::<5>(jobs),
        6 => run_n::<6>(jobs),
        _ => {}
    }
}

pub fn calibrate_lanes() -> usize {
    let mut jobs = [BcryptJob {
        cost: 6,
        password_len: 8,
        ..BcryptJob::default()
    }; BCRYPT_LANES];

    let mut best = 1usize;
    let mut best_us = -1i64;
    for n in 1..=BCRYPT_LANES {
        let t0 = clock_us();
        run(&mut jobs[..n]);
        run(&mut jobs[..n]);
        let per = (clock_us() - t0) / (n as i64);
        if best_us < 0 || per * 103 < best_us * 100 {
            best = n;
            best_us = per;
        }
    }
    best
}

