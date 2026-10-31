# gzip.s: gzip (RFC 1952) compression of response bodies, in the manner of libdeflate level 1 (what the Rust server
# uses): greedy LZ77 on a 2^15 x 2 hash table (min match 4, nice length 32; only a match's last 3 positions are
# inserted, where libdeflate inserts them all), blocks of up to 64 KB or 8192 matches, each written as dynamic
# Huffman, static Huffman or stored, whichever is smallest; CRC32 by PCLMULQDQ folding (table fallback).
#
#   gzip_init(ctx)                                  once per ctx (GZ_CTX_SIZE bytes, per thread, 64-byte aligned)
#   gzip_compress(ctx, src, len, dst, dstcap) -> n  the gzip member's length, or 0 when it would not be smaller than
#                                                   len (send the body plain) or does not fit in dstcap
#   gzip_bound(len) -> bytes                        a dstcap that never turns a smaller result into 0
#
# Header: 1f 8b 08 00, mtime 0, xfl 4 (fastest), os 0xff, as libdeflate writes. Positions are stored in the hash table
# as base + offset, with a base that moves past every input (by len + 32 KB + 1), so entries from earlier calls are
# simply out of the window and the table is cleared only once per 4 GB. Needs BMI2 (shlx/shrx); PCLMULQDQ + AVX are
# used for the CRC when present. SysV: callee-saved registers (r15 included) are preserved.
#
# Third-party notices:
# - The compressor's design and parameters (matchfinder, block splitting, cost-based block type, precode RLE,
#   length-limited Huffman build) follow libdeflate's deflate_compress.c, used under the MIT license:
#     Copyright 2016 Eric Biggers
#     Copyright 2024 Google LLC
#     Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
#     documentation files (the "Software"), to deal in the Software without restriction, including without limitation
#     the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
#     to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#     The above copyright notice and this permission notice shall be included in all copies or substantial portions
#     of the Software.
#     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
#     THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
#     CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
#     IN THE SOFTWARE.
# - .Lgz_crc is a translation of Chromium zlib's crc32_sse42_simd_ (third_party/zlib/crc32_simd.c), with its folding
#   constants, used under the BSD-style Chromium license:
#     Copyright 2017 The Chromium Authors
#     Redistribution and use in source and binary forms, with or without modification, are permitted provided that
#     the following conditions are met:
#       * Redistributions of source code must retain the above copyright notice, this list of conditions and the
#         following disclaimer.
#       * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
#         following disclaimer in the documentation and/or other materials provided with the distribution.
#       * Neither the name of Google LLC nor the names of its contributors may be used to endorse or promote products
#         derived from this software without specific prior written permission.
#     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
#     WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
#     PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY
#     DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
#     PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
#     CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
#     OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
.include "defs.inc"

.ifdef GZ_HB                            # experiment: other hash table sizes
.equ GZ_HBITS, GZ_HB
.else
.equ GZ_HBITS, 15
.endif
.equ GZ_HMUL, 0x1E35A7BD
.equ GZ_WSIZE, 32768
.equ GZ_SEQ_MAX, 8192
.equ GZ_BLOCK, 65535                    # FAST_SOFT_MAX_BLOCK_LENGTH
.equ GZ_MIN_BLOCK, 5000                 # MIN_BLOCK_LENGTH: a shorter tail joins the block before it

# ctx layout (GZ_CTX_SIZE in defs.inc)
.equ GZX_HT, 0                          # u32 [2^15][2] positions (base + offset)
.equ GZX_SEQ, GZX_HT + (8 << GZ_HBITS)  # {u32 literal run, u16 length (0 = end), u16 distance} [8192 + 1]
.equ GZX_FREQ, GZX_SEQ + 65600          # u32 [288] litlen frequencies
.equ GZX_DFREQ, GZX_FREQ + 288 * 4      # u32 [32] distance frequencies (contiguous with GZX_FREQ)
.equ GZX_CW, GZX_DFREQ + 32 * 4         # u32 [288 + 32] codewords: length | reversed code << 8
.equ GZX_LENS, GZX_CW + 320 * 4         # u8 [288 + 32] code lengths
.equ GZX_COMB, GZX_LENS + 320           # u8 [320] litlen + distance lengths as sent
.equ GZX_PITEMS, GZX_COMB + 320         # u32 [320] precode items: symbol | extra << 5
.equ GZX_PFREQ, GZX_PITEMS + 320 * 4    # u32 [32]
.equ GZX_PCW, GZX_PFREQ + 32 * 4        # u32 [32]
.equ GZX_PLENS, GZX_PCW + 32 * 4        # u8 [32]
.equ GZX_A, GZX_PLENS + 32              # u32 [288] Huffman work
.equ GZX_B, GZX_A + 288 * 4             # u32 [288]
.equ GZX_BASE, GZX_B + 288 * 4          # position base for the next call (0 = table not initialised)
.equ GZX_FLAGS, GZX_BASE + 8            # bit 0: PCLMULQDQ + AVX
.equ GZX_END, GZX_FLAGS + 8
.if GZX_END > GZ_CTX_SIZE
.error "GZ_CTX_SIZE too small"
.endif

# ---- gz_tab: generated by test/json/gen_gzip_tables.py
.equ T_K1K2, 0
.equ T_K3K4, 16
.equ T_K5, 32
.equ T_POLY, 48
.equ T_MASK, 64
.equ T_CRC, 80
.equ T_LENINFO, 1104
.equ T_DINFO, 2140
.equ T_DSYM, 2260
.equ T_REV8, 2772
.equ T_SLENS, 3028
.equ T_LEXT, 3348
.equ T_DEXT, 3377
.equ T_PERM, 3407
.equ T_PEXT, 3426
.section .rodata
.balign 64
gz_tab:
    .quad 0x154442bd4, 0x1c6e41596                         # T_K1K2
    .quad 0x1751997d0, 0xccaa009e                         # T_K3K4
    .quad 0x163cd6124, 0x0                         # T_K5
    .quad 0x1db710641, 0x1f7011641                         # T_POLY
    .quad 0xffffffff, 0xffffffff                         # T_MASK
    # T_CRC
    .long 0x0, 0x77073096, 0xee0e612c, 0x990951ba, 0x76dc419, 0x706af48f, 0xe963a535, 0x9e6495a3
    .long 0xedb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988, 0x9b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91
    .long 0x1db71064, 0x6ab020f2, 0xf3b97148, 0x84be41de, 0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7
    .long 0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9, 0xfa0f3d63, 0x8d080df5
    .long 0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172, 0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b
    .long 0x35b5a8fa, 0x42b2986c, 0xdbbbc9d6, 0xacbcf940, 0x32d86ce3, 0x45df5c75, 0xdcd60dcf, 0xabd13d59
    .long 0x26d930ac, 0x51de003a, 0xc8d75180, 0xbfd06116, 0x21b4f4b5, 0x56b3c423, 0xcfba9599, 0xb8bda50f
    .long 0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924, 0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d
    .long 0x76dc4190, 0x1db7106, 0x98d220bc, 0xefd5102a, 0x71b18589, 0x6b6b51f, 0x9fbfe4a5, 0xe8b8d433
    .long 0x7807c9a2, 0xf00f934, 0x9609a88e, 0xe10e9818, 0x7f6a0dbb, 0x86d3d2d, 0x91646c97, 0xe6635c01
    .long 0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e, 0x6c0695ed, 0x1b01a57b, 0x8208f4c1, 0xf50fc457
    .long 0x65b0d9c6, 0x12b7e950, 0x8bbeb8ea, 0xfcb9887c, 0x62dd1ddf, 0x15da2d49, 0x8cd37cf3, 0xfbd44c65
    .long 0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2, 0x4adfa541, 0x3dd895d7, 0xa4d1c46d, 0xd3d6f4fb
    .long 0x4369e96a, 0x346ed9fc, 0xad678846, 0xda60b8d0, 0x44042d73, 0x33031de5, 0xaa0a4c5f, 0xdd0d7cc9
    .long 0x5005713c, 0x270241aa, 0xbe0b1010, 0xc90c2086, 0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f
    .long 0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4, 0x59b33d17, 0x2eb40d81, 0xb7bd5c3b, 0xc0ba6cad
    .long 0xedb88320, 0x9abfb3b6, 0x3b6e20c, 0x74b1d29a, 0xead54739, 0x9dd277af, 0x4db2615, 0x73dc1683
    .long 0xe3630b12, 0x94643b84, 0xd6d6a3e, 0x7a6a5aa8, 0xe40ecf0b, 0x9309ff9d, 0xa00ae27, 0x7d079eb1
    .long 0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb, 0x196c3671, 0x6e6b06e7
    .long 0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc, 0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5
    .long 0xd6d6a3e8, 0xa1d1937e, 0x38d8c2c4, 0x4fdff252, 0xd1bb67f1, 0xa6bc5767, 0x3fb506dd, 0x48b2364b
    .long 0xd80d2bda, 0xaf0a1b4c, 0x36034af6, 0x41047a60, 0xdf60efc3, 0xa867df55, 0x316e8eef, 0x4669be79
    .long 0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236, 0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f
    .long 0xc5ba3bbe, 0xb2bd0b28, 0x2bb45a92, 0x5cb36a04, 0xc2d7ffa7, 0xb5d0cf31, 0x2cd99e8b, 0x5bdeae1d
    .long 0x9b64c2b0, 0xec63f226, 0x756aa39c, 0x26d930a, 0x9c0906a9, 0xeb0e363f, 0x72076785, 0x5005713
    .long 0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0xcb61b38, 0x92d28e9b, 0xe5d5be0d, 0x7cdcefb7, 0xbdbdf21
    .long 0x86d3d2d4, 0xf1d4e242, 0x68ddb3f8, 0x1fda836e, 0x81be16cd, 0xf6b9265b, 0x6fb077e1, 0x18b74777
    .long 0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c, 0x8f659eff, 0xf862ae69, 0x616bffd3, 0x166ccf45
    .long 0xa00ae278, 0xd70dd2ee, 0x4e048354, 0x3903b3c2, 0xa7672661, 0xd06016f7, 0x4969474d, 0x3e6e77db
    .long 0xaed16a4a, 0xd9d65adc, 0x40df0b66, 0x37d83bf0, 0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9
    .long 0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6, 0xbad03605, 0xcdd70693, 0x54de5729, 0x23d967bf
    .long 0xb3667a2e, 0xc4614ab8, 0x5d681b02, 0x2a6f2b94, 0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d
    # T_LENINFO
    .long 0x0, 0x0, 0x0, 0x0, 0x1, 0x2, 0x3, 0x4
    .long 0x5, 0x6, 0x7, 0x1000008, 0x1000108, 0x1000009, 0x1000109, 0x100000a
    .long 0x100010a, 0x100000b, 0x100010b, 0x200000c, 0x200010c, 0x200020c, 0x200030c, 0x200000d
    .long 0x200010d, 0x200020d, 0x200030d, 0x200000e, 0x200010e, 0x200020e, 0x200030e, 0x200000f
    .long 0x200010f, 0x200020f, 0x200030f, 0x3000010, 0x3000110, 0x3000210, 0x3000310, 0x3000410
    .long 0x3000510, 0x3000610, 0x3000710, 0x3000011, 0x3000111, 0x3000211, 0x3000311, 0x3000411
    .long 0x3000511, 0x3000611, 0x3000711, 0x3000012, 0x3000112, 0x3000212, 0x3000312, 0x3000412
    .long 0x3000512, 0x3000612, 0x3000712, 0x3000013, 0x3000113, 0x3000213, 0x3000313, 0x3000413
    .long 0x3000513, 0x3000613, 0x3000713, 0x4000014, 0x4000114, 0x4000214, 0x4000314, 0x4000414
    .long 0x4000514, 0x4000614, 0x4000714, 0x4000814, 0x4000914, 0x4000a14, 0x4000b14, 0x4000c14
    .long 0x4000d14, 0x4000e14, 0x4000f14, 0x4000015, 0x4000115, 0x4000215, 0x4000315, 0x4000415
    .long 0x4000515, 0x4000615, 0x4000715, 0x4000815, 0x4000915, 0x4000a15, 0x4000b15, 0x4000c15
    .long 0x4000d15, 0x4000e15, 0x4000f15, 0x4000016, 0x4000116, 0x4000216, 0x4000316, 0x4000416
    .long 0x4000516, 0x4000616, 0x4000716, 0x4000816, 0x4000916, 0x4000a16, 0x4000b16, 0x4000c16
    .long 0x4000d16, 0x4000e16, 0x4000f16, 0x4000017, 0x4000117, 0x4000217, 0x4000317, 0x4000417
    .long 0x4000517, 0x4000617, 0x4000717, 0x4000817, 0x4000917, 0x4000a17, 0x4000b17, 0x4000c17
    .long 0x4000d17, 0x4000e17, 0x4000f17, 0x5000018, 0x5000118, 0x5000218, 0x5000318, 0x5000418
    .long 0x5000518, 0x5000618, 0x5000718, 0x5000818, 0x5000918, 0x5000a18, 0x5000b18, 0x5000c18
    .long 0x5000d18, 0x5000e18, 0x5000f18, 0x5001018, 0x5001118, 0x5001218, 0x5001318, 0x5001418
    .long 0x5001518, 0x5001618, 0x5001718, 0x5001818, 0x5001918, 0x5001a18, 0x5001b18, 0x5001c18
    .long 0x5001d18, 0x5001e18, 0x5001f18, 0x5000019, 0x5000119, 0x5000219, 0x5000319, 0x5000419
    .long 0x5000519, 0x5000619, 0x5000719, 0x5000819, 0x5000919, 0x5000a19, 0x5000b19, 0x5000c19
    .long 0x5000d19, 0x5000e19, 0x5000f19, 0x5001019, 0x5001119, 0x5001219, 0x5001319, 0x5001419
    .long 0x5001519, 0x5001619, 0x5001719, 0x5001819, 0x5001919, 0x5001a19, 0x5001b19, 0x5001c19
    .long 0x5001d19, 0x5001e19, 0x5001f19, 0x500001a, 0x500011a, 0x500021a, 0x500031a, 0x500041a
    .long 0x500051a, 0x500061a, 0x500071a, 0x500081a, 0x500091a, 0x5000a1a, 0x5000b1a, 0x5000c1a
    .long 0x5000d1a, 0x5000e1a, 0x5000f1a, 0x500101a, 0x500111a, 0x500121a, 0x500131a, 0x500141a
    .long 0x500151a, 0x500161a, 0x500171a, 0x500181a, 0x500191a, 0x5001a1a, 0x5001b1a, 0x5001c1a
    .long 0x5001d1a, 0x5001e1a, 0x5001f1a, 0x500001b, 0x500011b, 0x500021b, 0x500031b, 0x500041b
    .long 0x500051b, 0x500061b, 0x500071b, 0x500081b, 0x500091b, 0x5000a1b, 0x5000b1b, 0x5000c1b
    .long 0x5000d1b, 0x5000e1b, 0x5000f1b, 0x500101b, 0x500111b, 0x500121b, 0x500131b, 0x500141b
    .long 0x500151b, 0x500161b, 0x500171b, 0x500181b, 0x500191b, 0x5001a1b, 0x5001b1b, 0x5001c1b
    .long 0x5001d1b, 0x5001e1b, 0x1c
    # T_DINFO
    .long 0x1, 0x2, 0x3, 0x4, 0x10005, 0x10007, 0x20009, 0x2000d
    .long 0x30011, 0x30019, 0x40021, 0x40031, 0x50041, 0x50061, 0x60081, 0x600c1
    .long 0x70101, 0x70181, 0x80201, 0x80301, 0x90401, 0x90601, 0xa0801, 0xa0c01
    .long 0xb1001, 0xb1801, 0xc2001, 0xc3001, 0xd4001, 0xd6001
    # T_DSYM
    .byte 0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10
    .byte 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11
    .byte 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12
    .byte 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12
    .byte 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13
    .byte 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13
    .byte 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
    .byte 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
    .byte 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
    .byte 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
    .byte 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15
    .byte 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15
    .byte 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15
    .byte 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15
    .byte 0, 0, 16, 17, 18, 18, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21
    .byte 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23
    .byte 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24
    .byte 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25
    .byte 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26
    .byte 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26
    .byte 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27
    .byte 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27
    .byte 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28
    .byte 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28
    .byte 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28
    .byte 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28
    .byte 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29
    .byte 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29
    .byte 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29
    .byte 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29
    # T_REV8
    .byte 0, 128, 64, 192, 32, 160, 96, 224, 16, 144, 80, 208, 48, 176, 112, 240
    .byte 8, 136, 72, 200, 40, 168, 104, 232, 24, 152, 88, 216, 56, 184, 120, 248
    .byte 4, 132, 68, 196, 36, 164, 100, 228, 20, 148, 84, 212, 52, 180, 116, 244
    .byte 12, 140, 76, 204, 44, 172, 108, 236, 28, 156, 92, 220, 60, 188, 124, 252
    .byte 2, 130, 66, 194, 34, 162, 98, 226, 18, 146, 82, 210, 50, 178, 114, 242
    .byte 10, 138, 74, 202, 42, 170, 106, 234, 26, 154, 90, 218, 58, 186, 122, 250
    .byte 6, 134, 70, 198, 38, 166, 102, 230, 22, 150, 86, 214, 54, 182, 118, 246
    .byte 14, 142, 78, 206, 46, 174, 110, 238, 30, 158, 94, 222, 62, 190, 126, 254
    .byte 1, 129, 65, 193, 33, 161, 97, 225, 17, 145, 81, 209, 49, 177, 113, 241
    .byte 9, 137, 73, 201, 41, 169, 105, 233, 25, 153, 89, 217, 57, 185, 121, 249
    .byte 5, 133, 69, 197, 37, 165, 101, 229, 21, 149, 85, 213, 53, 181, 117, 245
    .byte 13, 141, 77, 205, 45, 173, 109, 237, 29, 157, 93, 221, 61, 189, 125, 253
    .byte 3, 131, 67, 195, 35, 163, 99, 227, 19, 147, 83, 211, 51, 179, 115, 243
    .byte 11, 139, 75, 203, 43, 171, 107, 235, 27, 155, 91, 219, 59, 187, 123, 251
    .byte 7, 135, 71, 199, 39, 167, 103, 231, 23, 151, 87, 215, 55, 183, 119, 247
    .byte 15, 143, 79, 207, 47, 175, 111, 239, 31, 159, 95, 223, 63, 191, 127, 255
    # T_SLENS
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
    .byte 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7
    .byte 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8
    .byte 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
    .byte 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
    # T_LEXT
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2
    .byte 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
    # T_DEXT
    .byte 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6
    .byte 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
    # T_PERM
    .byte 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2
    .byte 14, 1, 15
    # T_PEXT
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 2, 3, 7
.text
# ---- gz_tab: end

# gzip_compress frame (after 6 pushes)
.equ F_SRC, 0
.equ F_LEN, 8
.equ F_DST, 16
.equ F_LIMIT, 24                        # the deflate data must end by here
.equ F_OUT, 32                          # bit writer: byte cursor, bit buffer, bit count
.equ F_BB, 40
.equ F_BC, 48
.equ F_BIAS, 56                         # position = (pointer + bias) mod 2^32
.equ F_BSTART, 64
.equ F_FINAL, 72
.equ F_HLIT, 80
.equ F_HDIST, 88
.equ F_HCLEN, 96
.equ F_NITEMS, 104
.equ F_BTYPE, 112
.equ F_FAST, 144                        # last position with 258 bytes ahead
.equ F_LIM, 160                         # min(block end, F_FAST): past it, the slow checks
.equ F_LITS, 168                        # start of the current literal run
.equ F_LLBITS, 120                      # litlen / distance data bits of the dynamic codes
.equ F_DBITS, 128
.equ FRAME, 184

.text

.globl gzip_bound
.type gzip_bound, @function
gzip_bound:
    lea rax, [rdi + 64]
    ret
.size gzip_bound, .-gzip_bound

.globl gzip_init
.type gzip_init, @function
gzip_init:
    mov qword ptr [rdi + GZX_BASE], 0
    ret
.size gzip_init, .-gzip_init

# Bit writer, in the block writer: rdi = output cursor, r8 = bit buffer, r9 = bit count (< 8 after GZ_FLUSH).

# GZ_PROF i: with --defsym GZ_PROF=1, add the cycles since the previous stamp to gz_prof[i] (test builds only)
.macro GZ_PROF i
.ifdef GZ_PROF
    pushfq
    push rax
    push rdx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rdx, rax
    sub rax, [rip + gz_prof + 248]
    mov [rip + gz_prof + 248], rdx
    add [rip + gz_prof + \i * 8], rax
    pop rdx
    pop rax
    popfq
.endif
.endm
.macro GZ_COUNT i, n
.ifdef GZ_COUNTS
    pushfq
    add qword ptr [rip + gz_prof + \i * 8], \n
    popfq
.endif
.endm
.ifdef GZ_PROF
.bss
.balign 8
.globl gz_prof
gz_prof: .zero 256                      # cycles: LZ, plan, emit, rest, between calls, plan parts, huff parts;
                                        # [16] literals [17] matches [18] matched bytes (GZ_COUNTS=1 too); [31] last stamp
.text
.endif

.macro GZ_FLUSH
    mov [rdi], r8
    mov edx, r9d
    shr edx, 3
    add rdi, rdx
    shl edx, 3
    shrx r8, r8, rdx
    and r9d, 7
.endm

# eax = codeword -> written (clobbers eax, edx)
.macro GZ_CW_EAX
    movzx edx, al
    shr eax, 8
    shlx rax, rax, r9
    or r8, rax
    add r9d, edx
.endm

# ---------------------------------------------------------------- gzip_compress
.globl gzip_compress
.type gzip_compress, @function
gzip_compress:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, FRAME
    GZ_PROF 4
    mov r12, rdi
    mov [rsp + F_SRC], rsi
    mov [rsp + F_LEN], rdx
    mov [rsp + F_DST], rcx
    lea rax, [r8 - 8]                   # room for the trailer
    lea r9, [rdx - 9]                   # header + deflate + 8 must be < len
    cmp rax, r9
    cmovg rax, r9
    cmp rax, 12
    jl .Lgz_fail
    add rax, rcx
    mov [rsp + F_LIMIT], rax
    mov rax, [r12 + GZX_BASE]
    test rax, rax
    jz .Lgz_reset
    lea r9, [rax + rdx + 2 * GZ_WSIZE + 2]
    shr r9, 32
    jnz .Lgz_reset
.Lgz_based:
    test byte ptr [r12 + GZX_FLAGS], 2
    jnz .Lgz_fail
    lea r9, [rax + rdx + GZ_WSIZE + 1]
    mov [r12 + GZX_BASE], r9
    sub eax, esi
    mov [rsp + F_BIAS], rax
    mov rax, 0x88b1f                    # 1f 8b 08 00, mtime 0
    mov [rcx], rax
    mov word ptr [rcx + 8], 0xff04      # xfl 4, os 0xff
    add rcx, 10
    mov [rsp + F_OUT], rcx
    xor eax, eax
    mov [rsp + F_BB], rax
    mov [rsp + F_BC], rax
    call .Lgz_clear_freqs
    mov r13, [rsp + F_SRC]
    mov r14, r13
    add r14, [rsp + F_LEN]
    lea rax, [r14 - 258]
    mov [rsp + F_FAST], rax
    jmp .Lz_block

.Lgz_reset:                             # first use, or the position space would wrap: clear the table
    mov rdi, r12
    mov ecx, 1 << GZ_HBITS              # qwords
    xor eax, eax
    rep stosq
    mov eax, 1
    xor ecx, ecx
    cpuid
    xor eax, eax
    bt ecx, 1                           # PCLMULQDQ
    adc eax, 0
    test byte ptr [rip + cpu_features], CPU_AVX2
    jnz 1f
    xor eax, eax
1:  test byte ptr [rip + cpu_features], CPU_BMI2
    jnz 2f
    or eax, 2                           # no BMI2: always answer 0 (plain)
2:  mov [r12 + GZX_FLAGS], rax
    mov eax, GZ_WSIZE + 1
    mov rsi, [rsp + F_SRC]
    mov rdx, [rsp + F_LEN]
    mov rcx, [rsp + F_DST]
    jmp .Lgz_based

# ---------------------------------------------------------------- LZ77 (r13 = cursor, r14 = end, r15 = block end,
# rbx = next sequence, ebp = position bias (F_BIAS), r11d = longest match allowed: 258 until F_FAST)
.Lz_block:
    GZ_PROF 3
    mov [rsp + F_BSTART], r13
    mov [rsp + F_LITS], r13
    mov rax, r14
    sub rax, r13
    lea r15, [r13 + GZ_BLOCK]
    cmp rax, GZ_BLOCK + GZ_MIN_BLOCK
    cmovb r15, r14
    mov rax, [rsp + F_FAST]
    cmp rax, r15
    cmova rax, r15
    mov [rsp + F_LIM], rax
    lea rbx, [r12 + GZX_SEQ]
    mov ebp, [rsp + F_BIAS]
    mov r11d, 258
    jmp .Lz_next
.Lz_lit:
    GZ_COUNT 16, 1
    movzx eax, byte ptr [r13]
    inc dword ptr [r12 + GZX_FREQ + rax * 4]
    inc r13
.Lz_next:
    cmp r13, [rsp + F_LIM]
    jae .Lz_slow
.Lz_find:
    mov r10d, [r13]
    imul eax, r10d, GZ_HMUL
    shr eax, 32 - GZ_HBITS
    mov rdx, [r12 + rax * 8]            # newest candidate | older << 32
    lea esi, [r13 + rbp]                # this position
    mov ecx, edx
    mov r9, rdx
    shl r9, 32
    or r9, rsi
    mov [r12 + rax * 8], r9
    shr rdx, 32
    mov r8d, esi
    sub r8d, ecx                        # distance to the newest
    lea eax, [r8 - 1]
    cmp eax, GZ_WSIZE - 1
    ja .Lz_lit                          # out of the window: the older one is too
    sub esi, edx                        # distance to the older
    lea eax, [rsi - 1]
    xor ecx, ecx
    cmp eax, GZ_WSIZE - 1
    cmova esi, ecx                      # 0 when out of the window (then it reads our own bytes: ignored)
    mov rdi, r13
    sub rdi, r8
    mov r9, r13
    sub r9, rsi
    cmp [rdi], r10d                     # both candidates at once: one (unpredictable) branch for a literal
    sete al
    cmp [r9], r10d
    sete cl
    test esi, esi
    setnz dl
    and cl, dl
    mov dl, al
    or dl, cl
    jz .Lz_lit
    test al, al
    jz .Lz_older
    mov dl, cl                          # the older one matches 4 bytes too
    call .Lz_extend
    cmp eax, 32
    jae .Lz_match
    cmp eax, r11d
    jae .Lz_match
    test dl, dl
    jz .Lz_match
    mov rdi, r9
    mov ecx, [rdi + rax - 3]            # it can only be longer if it matches up to one byte further
    cmp ecx, [r13 + rax - 3]
    jne .Lz_match
    mov edx, eax
    call .Lz_extend
    cmp eax, edx
    cmovbe eax, edx                     # the newer one on ties
    cmova r8d, esi
    jmp .Lz_match
.Lz_older:
    mov rdi, r9
    call .Lz_extend
    mov r8d, esi
.Lz_match:                              # eax = length, r8d = distance
    GZ_COUNT 17, 1
    GZ_COUNT 18, rax
    mov rcx, r13
    sub rcx, [rsp + F_LITS]
    mov [rbx], ecx
    mov [rbx + 4], ax
    mov [rbx + 6], r8w
    add rbx, 8
    lea rdx, [rip + gz_tab]
    movzx ecx, byte ptr [rdx + T_LENINFO + rax * 4]
    inc dword ptr [r12 + GZX_FREQ + 257 * 4 + rcx * 4]
    lea ecx, [r8 - 1]
    mov r9d, ecx
    shr r9d, 7
    add r9d, 256
    cmp ecx, 256
    cmovae ecx, r9d
    movzx ecx, byte ptr [rdx + T_DSYM + rcx]
    inc dword ptr [r12 + GZX_DFREQ + rcx * 4]
    mov rcx, r14
    sub rcx, r13
    lea edx, [rax + 5]
    lea rdi, [r13 + 1]
    add r13, rax
    mov [rsp + F_LITS], r13
    cmp rcx, rdx
    jb 2f                               # too near the end to hash (as libdeflate)
    # Hash only the match's last GZ_INSLAST positions (libdeflate hashes them all), branch-free: 3 never
    # repeats the match's first position (matches are 4+ long); +0.4% size on list pages for ~10% less time.
.ifndef GZ_INSLAST
.equ GZ_INSLAST, 3
.endif
.if GZ_INSLAST
.irp k, 8, 7, 6, 5, 4, 3, 2, 1
.if \k <= GZ_INSLAST
    imul ecx, [r13 - \k], GZ_HMUL
    shr ecx, 32 - GZ_HBITS
    lea esi, [r13 + rbp - \k]
    mov rdx, [r12 + rcx * 8]
    shl rdx, 32
    or rdx, rsi
    mov [r12 + rcx * 8], rdx
.endif
.endr
.else                                   # GZ_INSLAST=0: all of them, as libdeflate
    lea rax, [r13 - 1]
    cmp rdi, rax
    jae 1f
3:  imul ecx, [rdi], GZ_HMUL            # two at a time (in order: both may hit one bucket)
    imul r9d, [rdi + 1], GZ_HMUL
    shr ecx, 32 - GZ_HBITS
    shr r9d, 32 - GZ_HBITS
    lea esi, [rdi + rbp]
    mov rdx, [r12 + rcx * 8]
    shl rdx, 32
    or rdx, rsi
    mov [r12 + rcx * 8], rdx
    inc esi
    mov rdx, [r12 + r9 * 8]
    shl rdx, 32
    or rdx, rsi
    mov [r12 + r9 * 8], rdx
    add rdi, 2
    cmp rdi, rax
    jb 3b
1:  cmp rdi, r13
    jae 2f
    imul ecx, [rdi], GZ_HMUL
    shr ecx, 32 - GZ_HBITS
    lea esi, [rdi + rbp]
    mov rdx, [r12 + rcx * 8]
    shl rdx, 32
    or rdx, rsi
    mov [r12 + rcx * 8], rdx
.endif
2:  lea rax, [r12 + GZX_SEQ + GZ_SEQ_MAX * 8]
    cmp rbx, rax
    jb .Lz_next
    jmp .Lz_end_block
.Lz_slow:                               # at the block end, or under 258 bytes from the end
    cmp r13, r15
    jae .Lz_end_block
    mov rax, r14
    sub rax, r13
    cmp rax, 5
    jb .Lz_tail
    mov r11d, eax
    jmp .Lz_find
.Lz_tail:                               # under 5 bytes left: literals
    movzx eax, byte ptr [r13]
    inc dword ptr [r12 + GZX_FREQ + rax * 4]
    inc r13
    cmp r13, r14
    jb .Lz_tail
    jmp .Lz_end_block

# .Lz_extend: rdi = earlier copy whose first 4 bytes match r13's -> eax = match length (<= r11d). Clobbers rcx.
.Lz_extend:
    mov eax, 4
    cmp r11d, 258
    jne 1f
5:  mov rcx, [r13 + rax]                # 258 bytes ahead: no bounds checks until 252
    xor rcx, [rdi + rax]
    jnz 2f
    add eax, 8
    cmp eax, 252
    jb 5b
1:  lea ecx, [rax + 8]
    cmp ecx, r11d
    ja 3f
    mov rcx, [r13 + rax]
    xor rcx, [rdi + rax]
    jnz 2f
    add eax, 8
    jmp 1b
2:  bsf rcx, rcx
    shr ecx, 3
    add eax, ecx
    ret
3:  cmp eax, r11d
    jae 4f
    movzx ecx, byte ptr [r13 + rax]
    cmp cl, [rdi + rax]
    jne 4f
    inc eax
    jmp 3b
4:  ret

# ---------------------------------------------------------------- block writer
.Lz_end_block:
    GZ_PROF 0
    mov rax, r13
    sub rax, [rsp + F_LITS]
    mov [rbx], eax
    mov dword ptr [rbx + 4], 0
    xor eax, eax
    cmp r13, r14
    sete al
    mov [rsp + F_FINAL], rax
    mov dword ptr [r12 + GZX_FREQ + 256 * 4], 1
    lea rdi, [r12 + GZX_FREQ]
    mov esi, 286
    mov edx, 14                         # MAX_LITLEN_CODEWORD_LEN
    lea rcx, [r12 + GZX_CW]
    lea r8, [r12 + GZX_LENS]
    call .Lgz_huff
    GZ_PROF 5
    mov [rsp + F_LLBITS], rax
    lea rdi, [r12 + GZX_DFREQ]
    mov esi, 30
    mov edx, 15
    lea rcx, [r12 + GZX_CW + 288 * 4]
    lea r8, [r12 + GZX_LENS + 288]
    call .Lgz_huff
    GZ_PROF 6
    mov [rsp + F_DBITS], rax
    mov ecx, 286                        # HLIT: symbol 256 is always used
1:  cmp byte ptr [r12 + GZX_LENS + rcx - 1], 0
    jne 2f
    dec ecx
    jmp 1b
2:  mov [rsp + F_HLIT], rcx
    mov edx, 30                         # HDIST: two distance symbols always have lengths
3:  cmp byte ptr [r12 + GZX_LENS + 288 + rdx - 1], 0
    jne 4f
    dec edx
    jmp 3b
4:  mov [rsp + F_HDIST], rdx
    lea rsi, [r12 + GZX_LENS]
    lea rdi, [r12 + GZX_COMB]
    rep movsb
    lea rsi, [r12 + GZX_LENS + 288]
    mov rcx, rdx
    rep movsb
    mov rsi, [rsp + F_HLIT]
    add rsi, [rsp + F_HDIST]
    call .Lgz_precode
    mov [rsp + F_NITEMS], rax
    lea rdi, [r12 + GZX_PFREQ]
    mov esi, 19
    mov edx, 7
    lea rcx, [r12 + GZX_PCW]
    lea r8, [r12 + GZX_PLENS]
    call .Lgz_huff
    GZ_PROF 7
    mov r15, rax
    lea rsi, [rip + gz_tab]
    mov ecx, 19                         # HCLEN
5:  movzx eax, byte ptr [rsi + T_PERM + rcx - 1]
    cmp byte ptr [r12 + GZX_PLENS + rax], 0
    jne 6f
    dec ecx
    cmp ecx, 4
    ja 5b
6:  mov [rsp + F_HCLEN], rcx
    lea r15, [r15 + rcx * 2 + 17]       # dynamic header: 3 + 14 + 3 HCLEN + precode items with their extra bits
    add r15, rcx
    mov eax, [r12 + GZX_PFREQ + 16 * 4]
    lea r15, [r15 + rax * 2]
    mov eax, [r12 + GZX_PFREQ + 17 * 4]
    lea rax, [rax + rax * 2]
    add r15, rax
    mov eax, [r12 + GZX_PFREQ + 18 * 4]
    lea rdx, [rax * 8]
    sub rdx, rax
    add r15, rdx
    xor ebp, ebp                        # extra bits (either code)
    xor ecx, ecx
9:  mov eax, [r12 + GZX_FREQ + 257 * 4 + rcx * 4]
    movzx edx, byte ptr [rsi + T_LEXT + rcx]
    imul eax, edx
    add rbp, rax
    inc ecx
    cmp ecx, 29
    jb 9b
    xor ecx, ecx
10: mov eax, [r12 + GZX_DFREQ + rcx * 4]
    movzx edx, byte ptr [rsi + T_DEXT + rcx]
    imul eax, edx
    add rbp, rax
    inc ecx
    cmp ecx, 30
    jb 10b
    mov r8, r15                         # dynamic
    add r8, [rsp + F_LLBITS]
    add r8, [rsp + F_DBITS]
    add r8, rbp
    lea rdi, [r12 + GZX_FREQ]           # static: 8 bits for 0-143, 280-287; 9 for 144-255; 7 for 256-279; 5 a distance
    mov ecx, 36
    call .Lgz_sum
    lea r9, [rax * 8 + 3]
    lea rdi, [r12 + GZX_FREQ + 144 * 4]
    mov ecx, 28
    call .Lgz_sum
    lea rax, [rax + rax * 8]
    add r9, rax
    lea rdi, [r12 + GZX_FREQ + 256 * 4]
    mov ecx, 6
    call .Lgz_sum
    lea rdx, [rax * 8]
    sub rdx, rax
    add r9, rdx
    lea rdi, [r12 + GZX_FREQ + 280 * 4]
    mov ecx, 2
    call .Lgz_sum
    lea r9, [r9 + rax * 8]
    lea rdi, [r12 + GZX_DFREQ]
    mov ecx, 8
    call .Lgz_sum
    lea rax, [rax + rax * 4]
    add r9, rax
    add r9, rbp
    mov rax, r13
    sub rax, [rsp + F_BSTART]
    lea rcx, [rax + GZ_BLOCK - 1]
    xor edx, edx
    mov r10, rax
    mov rax, rcx
    mov ecx, GZ_BLOCK
    div rcx                             # stored chunks
    lea rax, [rax + rax * 4]
    shl rax, 3
    lea rax, [rax + r10 * 8 + 8]        # stored: 8 n + 40 per chunk + alignment
    mov ebx, 2
    mov rcx, r8
    cmp r9, rcx
    jae 11f
    mov ebx, 1
    mov rcx, r9
11: cmp rax, rcx
    jae 12f
    xor ebx, ebx
    mov rcx, rax
12: mov [rsp + F_BTYPE], rbx
    GZ_PROF 8
    add rcx, [rsp + F_BC]
    add rcx, 7
    shr rcx, 3
    add rcx, [rsp + F_OUT]
    cmp rcx, [rsp + F_LIMIT]
    ja .Lgz_fail
    test ebx, ebx
    jz .Lw_stored
    cmp ebx, 1
    jne .Lw_dynamic
    lea rsi, [rip + gz_tab + T_SLENS]   # static: fixed lengths, canonical codes
    lea rdi, [r12 + GZX_LENS]
    mov ecx, 320
    rep movsb
    lea rdi, [r12 + GZX_LENS]
    mov esi, 288
    lea rdx, [r12 + GZX_CW]
    call .Lgz_codes
    lea rdi, [r12 + GZX_LENS + 288]
    mov esi, 32
    lea rdx, [r12 + GZX_CW + 288 * 4]
    call .Lgz_codes
    mov rdi, [rsp + F_OUT]
    mov r8, [rsp + F_BB]
    mov r9, [rsp + F_BC]
    mov eax, [rsp + F_FINAL]
    or eax, 2
    shlx rax, rax, r9
    or r8, rax
    add r9d, 3
    lea rbp, [rip + gz_tab]
    jmp .Lw_seqs

.Lw_dynamic:
    mov rdi, [rsp + F_OUT]
    mov r8, [rsp + F_BB]
    mov r9, [rsp + F_BC]
    lea rbp, [rip + gz_tab]
    mov eax, [rsp + F_HLIT]
    sub eax, 257
    shl eax, 3
    mov ecx, [rsp + F_HDIST]
    dec ecx
    shl ecx, 8
    or eax, ecx
    mov ecx, [rsp + F_HCLEN]
    sub ecx, 4
    shl ecx, 13
    or eax, ecx
    or eax, [rsp + F_FINAL]
    or eax, 4                           # BTYPE 2
    shlx rax, rax, r9
    or r8, rax
    add r9d, 17
    GZ_FLUSH
    xor ecx, ecx
1:  movzx eax, byte ptr [rbp + T_PERM + rcx]
    movzx eax, byte ptr [r12 + GZX_PLENS + rax]
    shlx rax, rax, r9
    or r8, rax
    add r9d, 3
    GZ_FLUSH
    inc ecx
    cmp ecx, [rsp + F_HCLEN]
    jb 1b
    xor ecx, ecx
    jmp 3f
2:  mov r10d, [r12 + GZX_PITEMS + rcx * 4]
    mov r11d, r10d
    and r11d, 31
    mov eax, [r12 + GZX_PCW + r11 * 4]
    GZ_CW_EAX
    shr r10d, 5
    shlx r10, r10, r9
    or r8, r10
    movzx edx, byte ptr [rbp + T_PEXT + r11]
    add r9d, edx
    GZ_FLUSH
    inc ecx
3:  cmp ecx, [rsp + F_NITEMS]
    jb 2b

# sequences: rsi = source, rbx = sequence, r10 = codewords, rbp = gz_tab
.Lw_seqs:
    GZ_PROF 1
    mov rsi, [rsp + F_BSTART]
    lea rbx, [r12 + GZX_SEQ]
    lea r10, [r12 + GZX_CW]
.Lw_seq:
    mov r11d, [rbx]
.Lw_lit4:
    cmp r11d, 4
    jb .Lw_lit1
    movzx eax, byte ptr [rsi]
    mov eax, [r10 + rax * 4]
    GZ_CW_EAX
    movzx eax, byte ptr [rsi + 1]
    mov eax, [r10 + rax * 4]
    GZ_CW_EAX
    movzx eax, byte ptr [rsi + 2]
    mov eax, [r10 + rax * 4]
    GZ_CW_EAX
    movzx eax, byte ptr [rsi + 3]
    mov eax, [r10 + rax * 4]
    GZ_CW_EAX
    GZ_FLUSH
    add rsi, 4
    sub r11d, 4
    jmp .Lw_lit4
.Lw_lit1:
    test r11d, r11d
    jz .Lw_match
    movzx eax, byte ptr [rsi]
    mov eax, [r10 + rax * 4]
    GZ_CW_EAX
    GZ_FLUSH
    inc rsi
    dec r11d
    jmp .Lw_lit1
.Lw_match:
    movzx ecx, word ptr [rbx + 4]
    test ecx, ecx
    jz .Lw_eob
    mov r11d, [rbp + T_LENINFO + rcx * 4]   # index | extra << 8 | extra bits << 24
    movzx eax, r11b
    mov eax, [r10 + 257 * 4 + rax * 4]
    GZ_CW_EAX
    mov eax, r11d
    shr eax, 8
    movzx eax, al
    shlx rax, rax, r9
    or r8, rax
    shr r11d, 24
    add r9d, r11d
    movzx eax, word ptr [rbx + 6]
    lea edx, [rax - 1]
    mov r11d, edx
    shr r11d, 7
    add r11d, 256
    cmp edx, 256
    cmovae edx, r11d
    movzx edx, byte ptr [rbp + T_DSYM + rdx]
    mov r11d, [rbp + T_DINFO + rdx * 4]     # base | extra bits << 16
    mov edx, [r10 + 288 * 4 + rdx * 4]
    movzx r15d, r11w
    sub eax, r15d
    shr r11d, 16
    movzx r15d, dl
    shr edx, 8
    shlx rdx, rdx, r9
    or r8, rdx
    add r9d, r15d
    shlx rax, rax, r9
    or r8, rax
    add r9d, r11d
    GZ_FLUSH
    add rsi, rcx
    add rbx, 8
    jmp .Lw_seq
.Lw_eob:
    mov eax, [r10 + 256 * 4]
    GZ_CW_EAX
    GZ_FLUSH
.Lw_done:
    GZ_PROF 2
    mov [rsp + F_OUT], rdi
    mov [rsp + F_BB], r8
    mov [rsp + F_BC], r9
    call .Lgz_clear_freqs
    cmp r13, r14
    jb .Lz_block
    # end: last bits, CRC32, ISIZE
    mov [rdi], r8
    lea edx, [r9 + 7]
    shr edx, 3
    add rdi, rdx
    mov [rsp + F_OUT], rdi
    mov rdi, [rsp + F_SRC]
    mov rsi, [rsp + F_LEN]
    call .Lgz_crc
    mov rdi, [rsp + F_OUT]
    mov [rdi], eax
    mov rdx, [rsp + F_LEN]
    mov [rdi + 4], edx
    lea rax, [rdi + 8]
    sub rax, [rsp + F_DST]
    cmp rax, [rsp + F_LEN]
    jae .Lgz_fail
.Lgz_ret:
    GZ_PROF 3
    add rsp, FRAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lgz_fail:
    xor eax, eax
    jmp .Lgz_ret

.Lw_stored:                             # chunks of up to 65535 bytes, byte aligned
    mov rdi, [rsp + F_OUT]
    mov r8, [rsp + F_BB]
    mov r9, [rsp + F_BC]
    mov rsi, [rsp + F_BSTART]
    mov r11, r13
    sub r11, rsi
1:  mov ecx, GZ_BLOCK
    cmp r11, rcx
    cmovb ecx, r11d
    xor eax, eax
    cmp rcx, r11
    jne 2f
    mov eax, [rsp + F_FINAL]
2:  shlx rax, rax, r9
    or r8, rax
    add r9d, 3
    mov [rdi], r8
    lea edx, [r9 + 7]
    shr edx, 3
    add rdi, rdx
    xor r8d, r8d
    xor r9d, r9d
    mov [rdi], cx
    mov edx, ecx
    not edx
    mov [rdi + 2], dx
    add rdi, 4
    sub r11, rcx
    rep movsb
    test r11, r11
    jnz 1b
    jmp .Lw_done
.size gzip_compress, .-gzip_compress

# .Lgz_sum(rdi = 16-byte aligned u32[], ecx = count / 4) -> eax = their sum. Clobbers rdi, rcx, xmm0, xmm1.
.Lgz_sum:
    pxor xmm0, xmm0
1:  paddd xmm0, [rdi]
    add rdi, 16
    dec ecx
    jnz 1b
    pshufd xmm1, xmm0, 0x4e
    paddd xmm0, xmm1
    pshufd xmm1, xmm0, 0xb1
    paddd xmm0, xmm1
    movd eax, xmm0
    ret

# .Lgz_clear_freqs: zero GZX_FREQ + GZX_DFREQ (r12 = ctx). Clobbers rax, xmm0.
.Lgz_clear_freqs:
    pxor xmm0, xmm0
    xor eax, eax
1:  movdqa [r12 + GZX_FREQ + rax], xmm0
    movdqa [r12 + GZX_FREQ + rax + 16], xmm0
    movdqa [r12 + GZX_FREQ + rax + 32], xmm0
    movdqa [r12 + GZX_FREQ + rax + 48], xmm0
    add eax, 64
    cmp eax, 320 * 4
    jb 1b
    ret

# .Lgz_precode(esi = n): GZX_COMB[0..n) -> GZX_PITEMS (RLE with 16/17/18, as libdeflate), GZX_PFREQ; eax = items.
# Clobbers rcx, rdx, rdi, r8-r11, xmm0, xmm1.
.Lgz_precode:
    pxor xmm0, xmm0
    xor eax, eax
1:  movdqa [r12 + GZX_PFREQ + rax], xmm0
    add eax, 16
    cmp eax, 128
    jb 1b
    lea r8, [r12 + GZX_COMB]
    lea r9, [r12 + GZX_PITEMS]
    xor ecx, ecx                        # run start
.Lp_run:
    movzx eax, byte ptr [r8 + rcx]
    imul edi, eax, 0x01010101
    movd xmm1, edi
    pshufd xmm1, xmm1, 0
    lea edx, [rcx + 1]                  # run end, 16 lengths at a time (reads stay inside the ctx)
1:  movdqu xmm0, [r8 + rdx]
    pcmpeqb xmm0, xmm1
    pmovmskb edi, xmm0
    not edi
    bsf edi, edi
    add edx, edi
    cmp edi, 16
    jne 2f
    cmp edx, esi
    jb 1b
2:  cmp edx, esi
    cmova edx, esi
    test eax, eax
    jnz .Lp_nonzero
3:  mov r10d, edx                       # zeros: 18 (11..138), then 17 (3..10)
    sub r10d, ecx
    cmp r10d, 11
    jb 4f
    sub r10d, 11
    mov r11d, 127
    cmp r10d, r11d
    cmova r10d, r11d
    inc dword ptr [r12 + GZX_PFREQ + 18 * 4]
    mov r11d, r10d
    shl r11d, 5
    or r11d, 18
    mov [r9], r11d
    add r9, 4
    lea ecx, [rcx + r10 + 11]
    jmp 3b
4:  cmp r10d, 3
    jb .Lp_plain
    sub r10d, 3
    mov r11d, 7
    cmp r10d, r11d
    cmova r10d, r11d
    inc dword ptr [r12 + GZX_PFREQ + 17 * 4]
    mov r11d, r10d
    shl r11d, 5
    or r11d, 17
    mov [r9], r11d
    add r9, 4
    lea ecx, [rcx + r10 + 3]
    jmp .Lp_plain
.Lp_nonzero:
    mov r10d, edx
    sub r10d, ecx
    cmp r10d, 4
    jb .Lp_plain
    inc dword ptr [r12 + GZX_PFREQ + rax * 4]
    mov [r9], eax
    add r9, 4
    inc ecx
5:  mov r10d, edx                       # 16: repeat the previous 3..6 times
    sub r10d, ecx
    sub r10d, 3
    mov r11d, 3
    cmp r10d, r11d
    cmova r10d, r11d
    inc dword ptr [r12 + GZX_PFREQ + 16 * 4]
    mov r11d, r10d
    shl r11d, 5
    or r11d, 16
    mov [r9], r11d
    add r9, 4
    lea ecx, [rcx + r10 + 3]
    mov r10d, edx
    sub r10d, ecx
    cmp r10d, 3
    jae 5b
.Lp_plain:
    cmp ecx, edx
    je 6f
    inc dword ptr [r12 + GZX_PFREQ + rax * 4]
    mov [r9], eax
    add r9, 4
    inc ecx
    jmp .Lp_plain
6:  cmp ecx, esi
    jb .Lp_run
    lea rax, [r12 + GZX_PITEMS]
    sub r9, rax
    mov rax, r9
    shr rax, 2
    ret

# .Lgz_huff(rdi = u32 freq[], esi = symbols, edx = max length, rcx = u32 codewords out, r8 = u8 lengths out)
# -> rax = sum of frequency x length: a length-limited Huffman code (libdeflate's make_huffman_code: sort by
# frequency then symbol, in-place tree, length counts under the limit, lengths to symbols by frequency).
# r12 = ctx (GZX_A / GZX_B scratch). Clobbers the caller-saved registers.
.Lgz_huff:
    push rbx
    push rbp
    push r13
    push r14
    push r15
    sub rsp, 1104                       # [rsp] radix counts u32[64], [rsp + 1024] length counts u32[16],
    mov [rsp + 1088], rdi               # [rsp + 1088] freq, [rsp + 1096] result
    mov r13, rdi
    mov r14d, esi
    mov r15d, edx
    mov rbx, rcx
    mov rbp, r8
    pxor xmm1, xmm1
    xor eax, eax
0:  movdqu [rbp + rax], xmm1            # lengths: 0 (the arrays have room up to a multiple of 16)
    add eax, 16
    cmp eax, r14d
    jb 0b
    lea r9, [r12 + GZX_A]
    xor eax, eax
    xor r10d, r10d                      # used symbols
    xor r11d, r11d                      # OR of the frequencies
1:  movdqu xmm0, [r13 + rax * 4]        # 4 symbols at a time (frequencies past the count are 0): skip unused
    pcmpeqd xmm0, xmm1                  # groups, the rest branch-free
    movmskps ecx, xmm0
    cmp ecx, 15
    je 2f
.irp k, 0, 1, 2, 3
    mov ecx, [r13 + rax * 4 + 4 * \k]
    or r11d, ecx
    shl ecx, 10
    lea edx, [rax + \k]
    or ecx, edx
    mov [r9 + r10 * 4], ecx
    cmp ecx, 1024
    sbb r10d, -1                        # kept if the frequency isn't 0
.endr
2:  add eax, 4
    cmp eax, r14d
    jb 1b
    GZ_PROF 9
    cmp r10d, 2
    jb .Lh_few
    lea r8, [r12 + GZX_B]
    mov ecx, 10
.Lh_pass:                               # LSD radix on the frequency, 6 bits a pass (stable: ties keep symbol order)
    pxor xmm0, xmm0
    movdqa [rsp], xmm0
    movdqa [rsp + 16], xmm0
    movdqa [rsp + 32], xmm0
    movdqa [rsp + 48], xmm0
    movdqa [rsp + 64], xmm0
    movdqa [rsp + 80], xmm0
    movdqa [rsp + 96], xmm0
    movdqa [rsp + 112], xmm0
    movdqa [rsp + 128], xmm0
    movdqa [rsp + 144], xmm0
    movdqa [rsp + 160], xmm0
    movdqa [rsp + 176], xmm0
    movdqa [rsp + 192], xmm0
    movdqa [rsp + 208], xmm0
    movdqa [rsp + 224], xmm0
    movdqa [rsp + 240], xmm0
    xor eax, eax
4:  mov edx, [r9 + rax * 4]
    shr edx, cl
    and edx, 63
    inc dword ptr [rsp + rdx * 4]
    inc eax
    cmp eax, r10d
    jb 4b
    xor eax, eax
    xor edx, edx
5:  mov edi, [rsp + rax * 4]
    mov [rsp + rax * 4], edx
    add edx, edi
    inc eax
    cmp eax, 64
    jb 5b
    xor eax, eax
6:  mov esi, [r9 + rax * 4]
    mov edx, esi
    shr edx, cl
    and edx, 63
    mov edi, [rsp + rdx * 4]
    mov [r8 + rdi * 4], esi
    inc edi
    mov [rsp + rdx * 4], edi
    inc eax
    cmp eax, r10d
    jb 6b
    xchg r8, r9
    add ecx, 6
    shr r11d, 6
    jnz .Lh_pass
    GZ_PROF 10
    # build_tree: r9 = A, i = rax (next leaf), b = rcx (next unprocessed internal), e = rdx (next internal slot)
    lea r11d, [r10 - 1]                 # last leaf
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
.Lbt:
    mov r13d, edx
    shl r13d, 10                        # parent link for the children
    lea rsi, [rax + 1]
    cmp rsi, r11
    ja .Lbt_not2
    cmp rcx, rdx
    je .Lbt_2leaves
    mov edi, [r9 + rsi * 4]
    and edi, -1024
    mov r8d, [r9 + rcx * 4]
    and r8d, -1024
    cmp edi, r8d
    ja .Lbt_not2
.Lbt_2leaves:
    mov edi, [r9 + rax * 4]
    and edi, -1024
    mov r8d, [r9 + rsi * 4]
    and r8d, -1024
    add edi, r8d
    add rax, 2
    jmp .Lbt_store
.Lbt_not2:
    lea rsi, [rcx + 2]
    cmp rsi, rdx
    ja .Lbt_mixed
    cmp rax, r11
    ja .Lbt_2nodes
    mov edi, [r9 + rcx * 4 + 4]
    and edi, -1024
    mov r8d, [r9 + rax * 4]
    and r8d, -1024
    cmp edi, r8d
    jae .Lbt_mixed
.Lbt_2nodes:
    mov edi, [r9 + rcx * 4]
    mov r8d, edi
    and edi, -1024
    and r8d, 1023
    or r8d, r13d
    mov [r9 + rcx * 4], r8d
    mov r8d, [r9 + rcx * 4 + 4]
    mov esi, r8d
    and esi, -1024
    add edi, esi
    and r8d, 1023
    or r8d, r13d
    mov [r9 + rcx * 4 + 4], r8d
    add rcx, 2
    jmp .Lbt_store
.Lbt_mixed:
    mov edi, [r9 + rax * 4]
    and edi, -1024
    mov r8d, [r9 + rcx * 4]
    mov esi, r8d
    and esi, -1024
    add edi, esi
    and r8d, 1023
    or r8d, r13d
    mov [r9 + rcx * 4], r8d
    inc rax
    inc rcx
.Lbt_store:
    mov r8d, [r9 + rdx * 4]
    and r8d, 1023
    or r8d, edi
    mov [r9 + rdx * 4], r8d
    inc rdx
    cmp rdx, r11
    jb .Lbt
    GZ_PROF 11
    # length counts with the limit (compute_length_counts)
    pxor xmm0, xmm0
    movdqa [rsp + 1024], xmm0
    movdqa [rsp + 1040], xmm0
    movdqa [rsp + 1056], xmm0
    movdqa [rsp + 1072], xmm0
    mov dword ptr [rsp + 1024 + 4], 2
    lea rax, [r10 - 2]                  # root
    and dword ptr [r9 + rax * 4], 1023
    dec rax
    js 9f
7:  mov ecx, [r9 + rax * 4]
    mov edx, ecx
    shr edx, 10
    mov edx, [r9 + rdx * 4]
    shr edx, 10
    inc edx                             # depth
    and ecx, 1023
    mov esi, edx
    shl esi, 10
    or ecx, esi
    mov [r9 + rax * 4], ecx
    cmp edx, r15d
    jb 8f
    mov edx, r15d
6:  dec edx
    cmp dword ptr [rsp + 1024 + rdx * 4], 0
    je 6b
8:  dec dword ptr [rsp + 1024 + rdx * 4]
    add dword ptr [rsp + 1024 + rdx * 4 + 4], 2
    dec rax
    jns 7b
9:  xor eax, eax                        # longest lengths to the least frequent symbols
    mov ecx, r15d
    mov r8, [rsp + 1088]
    xor edi, edi
10: mov edx, [rsp + 1024 + rcx * 4]
    test edx, edx
    jz 12f
11: mov esi, [r9 + rax * 4]
    and esi, 1023
    mov [rbp + rsi], cl
    mov esi, [r8 + rsi * 4]
    imul esi, ecx
    add rdi, rsi
    inc eax
    dec edx
    jnz 11b
12: dec ecx
    jnz 10b
    mov [rsp + 1096], rdi
    GZ_PROF 12
.Lh_codes:
    mov rdi, rbp
    mov esi, r14d
    mov rdx, rbx
    lea rcx, [rsp + 1024]
    call .Lgz_codes_n
    GZ_PROF 13
    mov rax, [rsp + 1096]
    add rsp, 1104
    pop r15
    pop r14
    pop r13
    pop rbp
    pop rbx
    ret
.Lh_few:                                # under 2 used symbols: two 1-bit codes (symbol 0 and the used one, or 1)
    pxor xmm0, xmm0
    movdqa [rsp + 1024], xmm0
    movdqa [rsp + 1040], xmm0
    movdqa [rsp + 1056], xmm0
    movdqa [rsp + 1072], xmm0
    mov dword ptr [rsp + 1024 + 4], 2
    xor eax, eax
    test r10d, r10d
    jz 1f
    mov eax, [r9]
    and eax, 1023
1:  mov ecx, 1
    test eax, eax
    cmovnz ecx, eax
    mov byte ptr [rbp], 1
    mov byte ptr [rbp + rcx], 1
    mov edx, [r13 + rax * 4]            # the used symbol's (or symbol 0's zero) frequency, 1 bit each
    mov [rsp + 1096], rdx
    jmp .Lh_codes

# .Lgz_codes(rdi = u8 lengths, esi = symbols, rdx = u32 codewords out): canonical codes, bit-reversed, as
# length | code << 8 (unused symbols' entries are junk). .Lgz_codes_n: the same with rcx = u32 [16] counts of
# each length (index = length). The arrays must have room up to a multiple of 8 symbols.
.Lgz_codes:
    sub rsp, 136                        # [rsp] counts u32[16], [rsp + 64] next code u32[16]
    pxor xmm0, xmm0
    movdqa [rsp], xmm0
    movdqa [rsp + 16], xmm0
    movdqa [rsp + 32], xmm0
    movdqa [rsp + 48], xmm0
    xor eax, eax
1:  movzx ecx, byte ptr [rdi + rax]
    inc dword ptr [rsp + rcx * 4]
    inc eax
    cmp eax, esi
    jb 1b
    jmp .Lc_next
.Lgz_codes_n:
    sub rsp, 136
    movdqu xmm0, [rcx]
    movdqa [rsp], xmm0
    movdqu xmm0, [rcx + 16]
    movdqa [rsp + 16], xmm0
    movdqu xmm0, [rcx + 32]
    movdqa [rsp + 32], xmm0
    movdqu xmm0, [rcx + 48]
    movdqa [rsp + 48], xmm0
.Lc_next:
    mov dword ptr [rsp], 0
    xor eax, eax
    mov ecx, 1
2:  add eax, [rsp + rcx * 4 - 4]
    add eax, eax
    mov [rsp + 64 + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb 2b
    lea r8, [rip + gz_tab + T_REV8]
    xor r9d, r9d
3:  cmp qword ptr [rdi + r9], 0         # 8 symbols at a time: skip unused groups, the rest branch-free
    je 5f                               # (an unused symbol takes a junk code through next code [0])
.rept 8
    movzx ecx, byte ptr [rdi + r9]
    mov r10d, [rsp + 64 + rcx * 4]
    lea r11d, [r10 + 1]
    mov [rsp + 64 + rcx * 4], r11d
    movzx eax, r10b
    movzx eax, byte ptr [r8 + rax]
    shl eax, 8
    shr r10d, 8
    movzx r10d, r10b
    movzx r10d, byte ptr [r8 + r10]
    or eax, r10d
    mov r11d, 16
    sub r11d, ecx
    shrx eax, eax, r11d
    shl eax, 8
    or eax, ecx
    mov [rdx + r9 * 4], eax
    inc r9d
.endr
    cmp r9d, esi
    jb 3b
    add rsp, 136
    ret
5:  add r9d, 8
    cmp r9d, esi
    jb 3b
    add rsp, 136
    ret

# .Lgz_crc(rdi = buf, rsi = len) -> eax = CRC32 (gzip). PCLMULQDQ folding by 4 x 128 bits, then 128, Barrett
# reduction (Chromium zlib's crc32_sse42_simd_); bytes past the last 16-byte block (and short inputs) by table.
.Lgz_crc:
    mov eax, -1
    cmp rsi, 64
    jb .Lc_tail
    test byte ptr [r12 + GZX_FLAGS], 1
    jz .Lc_tail
    lea rdx, [rip + gz_tab]
    vmovdqu xmm1, [rdi]
    vmovdqu xmm2, [rdi + 16]
    vmovdqu xmm3, [rdi + 32]
    vmovdqu xmm4, [rdi + 48]
    vmovd xmm0, eax
    vpxor xmm1, xmm1, xmm0
    vmovdqa xmm0, [rdx + T_K1K2]
    add rdi, 64
    sub rsi, 64
1:  cmp rsi, 64
    jb 2f
    vpclmulqdq xmm5, xmm1, xmm0, 0x00
    vpclmulqdq xmm6, xmm2, xmm0, 0x00
    vpclmulqdq xmm7, xmm3, xmm0, 0x00
    vpclmulqdq xmm8, xmm4, xmm0, 0x00
    vpclmulqdq xmm1, xmm1, xmm0, 0x11
    vpclmulqdq xmm2, xmm2, xmm0, 0x11
    vpclmulqdq xmm3, xmm3, xmm0, 0x11
    vpclmulqdq xmm4, xmm4, xmm0, 0x11
    vpxor xmm1, xmm1, xmm5
    vpxor xmm2, xmm2, xmm6
    vpxor xmm3, xmm3, xmm7
    vpxor xmm4, xmm4, xmm8
    vpxor xmm1, xmm1, [rdi]
    vpxor xmm2, xmm2, [rdi + 16]
    vpxor xmm3, xmm3, [rdi + 32]
    vpxor xmm4, xmm4, [rdi + 48]
    add rdi, 64
    sub rsi, 64
    jmp 1b
2:  vmovdqa xmm0, [rdx + T_K3K4]
    vpclmulqdq xmm5, xmm1, xmm0, 0x00
    vpclmulqdq xmm1, xmm1, xmm0, 0x11
    vpxor xmm1, xmm1, xmm2
    vpxor xmm1, xmm1, xmm5
    vpclmulqdq xmm5, xmm1, xmm0, 0x00
    vpclmulqdq xmm1, xmm1, xmm0, 0x11
    vpxor xmm1, xmm1, xmm3
    vpxor xmm1, xmm1, xmm5
    vpclmulqdq xmm5, xmm1, xmm0, 0x00
    vpclmulqdq xmm1, xmm1, xmm0, 0x11
    vpxor xmm1, xmm1, xmm4
    vpxor xmm1, xmm1, xmm5
3:  cmp rsi, 16
    jb 4f
    vpclmulqdq xmm5, xmm1, xmm0, 0x00
    vpclmulqdq xmm1, xmm1, xmm0, 0x11
    vpxor xmm1, xmm1, [rdi]
    vpxor xmm1, xmm1, xmm5
    add rdi, 16
    sub rsi, 16
    jmp 3b
4:  vpclmulqdq xmm2, xmm1, xmm0, 0x10   # 128 -> 64 bits
    vmovdqa xmm3, [rdx + T_MASK]
    vpsrldq xmm1, xmm1, 8
    vpxor xmm1, xmm1, xmm2
    vmovq xmm0, [rdx + T_K5]
    vpsrldq xmm2, xmm1, 4
    vpand xmm1, xmm1, xmm3
    vpclmulqdq xmm1, xmm1, xmm0, 0x00
    vpxor xmm1, xmm1, xmm2
    vmovdqa xmm0, [rdx + T_POLY]        # Barrett
    vpand xmm2, xmm1, xmm3
    vpclmulqdq xmm2, xmm2, xmm0, 0x10
    vpand xmm2, xmm2, xmm3
    vpclmulqdq xmm2, xmm2, xmm0, 0x00
    vpxor xmm1, xmm1, xmm2
    vpextrd eax, xmm1, 1
.Lc_tail:
    test rsi, rsi
    jz 6f
    lea rdx, [rip + gz_tab + T_CRC]
5:  movzx ecx, byte ptr [rdi]
    xor cl, al
    shr eax, 8
    xor eax, [rdx + rcx * 4]
    inc rdi
    dec rsi
    jnz 5b
6:  not eax
    ret

.section .note.GNU-stack,"",@progbits
