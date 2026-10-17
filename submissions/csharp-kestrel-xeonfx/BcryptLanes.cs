// 3- and 4-lane bcrypt: the 2-lane scheme of Bcrypt.cs widened. Lane k's state starts at k * Lane.
using System;
using System.Runtime.CompilerServices;

namespace Conduit;

public static unsafe partial class Bcrypt
{
    public const int MaxLanes = 4;

    /// <summary>1 to <see cref="MaxLanes"/> jobs, interleaved on this thread.</summary>
    public static void Run(ReadOnlySpan<BcryptJob> jobs)
    {
        switch (jobs.Length)
        {
            case 1: Run(jobs[0]); break;
            case 2: Run(jobs[0], jobs[1]); break;
            case 3: Run(jobs[0], jobs[1], jobs[2]); break;
            case 4: Run(jobs[0], jobs[1], jobs[2], jobs[3]); break;
            default: throw new ArgumentOutOfRangeException(nameof(jobs), jobs.Length, "1 to 4 jobs");
        }
    }

    /// <summary>3 hashes interleaved on this thread.</summary>
    public static void Run(BcryptJob a, BcryptJob b, BcryptJob c)
    {
        if (b.Cost != a.Cost || c.Cost != a.Cost) { Run(a); Run(b); Run(c); return; }
        uint* st = stackalloc uint[3 * Lane];
        Init(st);
        Init(st + 1 * Lane);
        Init(st + 2 * Lane);
        fixed (uint* ka = a.KeyWords, sa = a.SaltWords, kb = b.KeyWords, sb = b.SaltWords, kc = c.KeyWords, sc = c.SaltWords)
        {
            ExpandState3(st, ka, sa, kb, sb, kc, sc);
            for (long n = 1L << a.Cost; n > 0; n--)
            {
                Expand0State3(st, ka, kb, kc);
                Expand0State3(st, sa, sb, sc);
            }
        }
        uint* ct = stackalloc uint[18];
        Ctext.CopyTo(new Span<uint>(ct + 0, 6));
        Ctext.CopyTo(new Span<uint>(ct + 6, 6));
        Ctext.CopyTo(new Span<uint>(ct + 12, 6));
        for (int i = 0; i < 64; i++)
            for (int k = 0; k < 6; k += 2)
                Encipher3(st, ref ct[0 + k], ref ct[1 + k], ref ct[6 + k], ref ct[7 + k], ref ct[12 + k], ref ct[13 + k]);
        Output(ct + 0, a.Hash);
        Output(ct + 6, b.Hash);
        Output(ct + 12, c.Hash);
    }

    static void ExpandState3(uint* st, uint* k0, uint* s0, uint* k1, uint* s1, uint* k2, uint* s2)
    {
        for (int i = 0; i < 18; i++) { st[P + i] ^= k0[i]; st[1 * Lane + P + i] ^= k1[i]; st[2 * Lane + P + i] ^= k2[i]; }
        uint l0 = 0, r0 = 0, l1 = 0, r1 = 0, l2 = 0, r2 = 0;
        int j = 0;
        for (int i = 0; i < 18; i += 2)
        {
            l0 ^= s0[j]; r0 ^= s0[j + 1]; l1 ^= s1[j]; r1 ^= s1[j + 1]; l2 ^= s2[j]; r2 ^= s2[j + 1]; j = (j + 2) & 3;
            Encipher3(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2);
            st[P + i] = l0; st[P + i + 1] = r0; st[1 * Lane + P + i] = l1; st[1 * Lane + P + i + 1] = r1; st[2 * Lane + P + i] = l2; st[2 * Lane + P + i + 1] = r2;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            l0 ^= s0[j]; r0 ^= s0[j + 1]; l1 ^= s1[j]; r1 ^= s1[j + 1]; l2 ^= s2[j]; r2 ^= s2[j + 1]; j = (j + 2) & 3;
            Encipher3(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2);
            st[S + i] = l0; st[S + i + 1] = r0; st[1 * Lane + S + i] = l1; st[1 * Lane + S + i + 1] = r1; st[2 * Lane + S + i] = l2; st[2 * Lane + S + i + 1] = r2;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Expand0State3(uint* st, uint* w0, uint* w1, uint* w2)
    {
        for (int i = 0; i < 18; i++) { st[P + i] ^= w0[i]; st[1 * Lane + P + i] ^= w1[i]; st[2 * Lane + P + i] ^= w2[i]; }
        uint l0 = 0, r0 = 0, l1 = 0, r1 = 0, l2 = 0, r2 = 0;
        for (int i = 0; i < 18; i += 2)
        {
            Encipher3(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2);
            st[P + i] = l0; st[P + i + 1] = r0; st[1 * Lane + P + i] = l1; st[1 * Lane + P + i + 1] = r1; st[2 * Lane + P + i] = l2; st[2 * Lane + P + i + 1] = r2;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            Encipher3(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2);
            st[S + i] = l0; st[S + i + 1] = r0; st[1 * Lane + S + i] = l1; st[1 * Lane + S + i + 1] = r1; st[2 * Lane + S + i] = l2; st[2 * Lane + S + i + 1] = r2;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher3(uint* st, ref uint xl0, ref uint xr0, ref uint xl1, ref uint xr1, ref uint xl2, ref uint xr2)
    {
        uint l0 = xl0 ^ st[P], r0 = xr0; uint l1 = xl1 ^ st[1 * Lane + P], r1 = xr1; uint l2 = xl2 ^ st[2 * Lane + P], r2 = xr2;
        r0 ^= F(st, l0) ^ st[P + 1]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 1]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 1];
        l0 ^= F(st, r0) ^ st[P + 2]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 2]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 2];
        r0 ^= F(st, l0) ^ st[P + 3]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 3]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 3];
        l0 ^= F(st, r0) ^ st[P + 4]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 4]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 4];
        r0 ^= F(st, l0) ^ st[P + 5]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 5]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 5];
        l0 ^= F(st, r0) ^ st[P + 6]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 6]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 6];
        r0 ^= F(st, l0) ^ st[P + 7]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 7]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 7];
        l0 ^= F(st, r0) ^ st[P + 8]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 8]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 8];
        r0 ^= F(st, l0) ^ st[P + 9]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 9]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 9];
        l0 ^= F(st, r0) ^ st[P + 10]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 10]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 10];
        r0 ^= F(st, l0) ^ st[P + 11]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 11]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 11];
        l0 ^= F(st, r0) ^ st[P + 12]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 12]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 12];
        r0 ^= F(st, l0) ^ st[P + 13]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 13]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 13];
        l0 ^= F(st, r0) ^ st[P + 14]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 14]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 14];
        r0 ^= F(st, l0) ^ st[P + 15]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 15]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 15];
        l0 ^= F(st, r0) ^ st[P + 16]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 16]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 16];
        xl0 = r0 ^ st[P + 17]; xr0 = l0; xl1 = r1 ^ st[1 * Lane + P + 17]; xr1 = l1; xl2 = r2 ^ st[2 * Lane + P + 17]; xr2 = l2;
    }

    /// <summary>4 hashes interleaved on this thread.</summary>
    public static void Run(BcryptJob a, BcryptJob b, BcryptJob c, BcryptJob d)
    {
        if (b.Cost != a.Cost || c.Cost != a.Cost || d.Cost != a.Cost) { Run(a); Run(b); Run(c); Run(d); return; }
        uint* st = stackalloc uint[4 * Lane];
        Init(st);
        Init(st + 1 * Lane);
        Init(st + 2 * Lane);
        Init(st + 3 * Lane);
        fixed (uint* ka = a.KeyWords, sa = a.SaltWords, kb = b.KeyWords, sb = b.SaltWords, kc = c.KeyWords, sc = c.SaltWords, kd = d.KeyWords, sd = d.SaltWords)
        {
            ExpandState4(st, ka, sa, kb, sb, kc, sc, kd, sd);
            for (long n = 1L << a.Cost; n > 0; n--)
            {
                Expand0State4(st, ka, kb, kc, kd);
                Expand0State4(st, sa, sb, sc, sd);
            }
        }
        uint* ct = stackalloc uint[24];
        Ctext.CopyTo(new Span<uint>(ct + 0, 6));
        Ctext.CopyTo(new Span<uint>(ct + 6, 6));
        Ctext.CopyTo(new Span<uint>(ct + 12, 6));
        Ctext.CopyTo(new Span<uint>(ct + 18, 6));
        for (int i = 0; i < 64; i++)
            for (int k = 0; k < 6; k += 2)
                Encipher4(st, ref ct[0 + k], ref ct[1 + k], ref ct[6 + k], ref ct[7 + k], ref ct[12 + k], ref ct[13 + k], ref ct[18 + k], ref ct[19 + k]);
        Output(ct + 0, a.Hash);
        Output(ct + 6, b.Hash);
        Output(ct + 12, c.Hash);
        Output(ct + 18, d.Hash);
    }

    static void ExpandState4(uint* st, uint* k0, uint* s0, uint* k1, uint* s1, uint* k2, uint* s2, uint* k3, uint* s3)
    {
        for (int i = 0; i < 18; i++) { st[P + i] ^= k0[i]; st[1 * Lane + P + i] ^= k1[i]; st[2 * Lane + P + i] ^= k2[i]; st[3 * Lane + P + i] ^= k3[i]; }
        uint l0 = 0, r0 = 0, l1 = 0, r1 = 0, l2 = 0, r2 = 0, l3 = 0, r3 = 0;
        int j = 0;
        for (int i = 0; i < 18; i += 2)
        {
            l0 ^= s0[j]; r0 ^= s0[j + 1]; l1 ^= s1[j]; r1 ^= s1[j + 1]; l2 ^= s2[j]; r2 ^= s2[j + 1]; l3 ^= s3[j]; r3 ^= s3[j + 1]; j = (j + 2) & 3;
            Encipher4(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2, ref l3, ref r3);
            st[P + i] = l0; st[P + i + 1] = r0; st[1 * Lane + P + i] = l1; st[1 * Lane + P + i + 1] = r1; st[2 * Lane + P + i] = l2; st[2 * Lane + P + i + 1] = r2; st[3 * Lane + P + i] = l3; st[3 * Lane + P + i + 1] = r3;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            l0 ^= s0[j]; r0 ^= s0[j + 1]; l1 ^= s1[j]; r1 ^= s1[j + 1]; l2 ^= s2[j]; r2 ^= s2[j + 1]; l3 ^= s3[j]; r3 ^= s3[j + 1]; j = (j + 2) & 3;
            Encipher4(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2, ref l3, ref r3);
            st[S + i] = l0; st[S + i + 1] = r0; st[1 * Lane + S + i] = l1; st[1 * Lane + S + i + 1] = r1; st[2 * Lane + S + i] = l2; st[2 * Lane + S + i + 1] = r2; st[3 * Lane + S + i] = l3; st[3 * Lane + S + i + 1] = r3;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Expand0State4(uint* st, uint* w0, uint* w1, uint* w2, uint* w3)
    {
        for (int i = 0; i < 18; i++) { st[P + i] ^= w0[i]; st[1 * Lane + P + i] ^= w1[i]; st[2 * Lane + P + i] ^= w2[i]; st[3 * Lane + P + i] ^= w3[i]; }
        uint l0 = 0, r0 = 0, l1 = 0, r1 = 0, l2 = 0, r2 = 0, l3 = 0, r3 = 0;
        for (int i = 0; i < 18; i += 2)
        {
            Encipher4(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2, ref l3, ref r3);
            st[P + i] = l0; st[P + i + 1] = r0; st[1 * Lane + P + i] = l1; st[1 * Lane + P + i + 1] = r1; st[2 * Lane + P + i] = l2; st[2 * Lane + P + i + 1] = r2; st[3 * Lane + P + i] = l3; st[3 * Lane + P + i + 1] = r3;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            Encipher4(st, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2, ref l3, ref r3);
            st[S + i] = l0; st[S + i + 1] = r0; st[1 * Lane + S + i] = l1; st[1 * Lane + S + i + 1] = r1; st[2 * Lane + S + i] = l2; st[2 * Lane + S + i + 1] = r2; st[3 * Lane + S + i] = l3; st[3 * Lane + S + i + 1] = r3;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher4(uint* st, ref uint xl0, ref uint xr0, ref uint xl1, ref uint xr1, ref uint xl2, ref uint xr2, ref uint xl3, ref uint xr3)
    {
        uint l0 = xl0 ^ st[P], r0 = xr0; uint l1 = xl1 ^ st[1 * Lane + P], r1 = xr1; uint l2 = xl2 ^ st[2 * Lane + P], r2 = xr2; uint l3 = xl3 ^ st[3 * Lane + P], r3 = xr3;
        r0 ^= F(st, l0) ^ st[P + 1]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 1]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 1]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 1];
        l0 ^= F(st, r0) ^ st[P + 2]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 2]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 2]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 2];
        r0 ^= F(st, l0) ^ st[P + 3]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 3]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 3]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 3];
        l0 ^= F(st, r0) ^ st[P + 4]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 4]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 4]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 4];
        r0 ^= F(st, l0) ^ st[P + 5]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 5]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 5]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 5];
        l0 ^= F(st, r0) ^ st[P + 6]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 6]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 6]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 6];
        r0 ^= F(st, l0) ^ st[P + 7]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 7]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 7]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 7];
        l0 ^= F(st, r0) ^ st[P + 8]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 8]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 8]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 8];
        r0 ^= F(st, l0) ^ st[P + 9]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 9]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 9]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 9];
        l0 ^= F(st, r0) ^ st[P + 10]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 10]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 10]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 10];
        r0 ^= F(st, l0) ^ st[P + 11]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 11]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 11]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 11];
        l0 ^= F(st, r0) ^ st[P + 12]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 12]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 12]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 12];
        r0 ^= F(st, l0) ^ st[P + 13]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 13]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 13]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 13];
        l0 ^= F(st, r0) ^ st[P + 14]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 14]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 14]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 14];
        r0 ^= F(st, l0) ^ st[P + 15]; r1 ^= F(st + 1 * Lane, l1) ^ st[1 * Lane + P + 15]; r2 ^= F(st + 2 * Lane, l2) ^ st[2 * Lane + P + 15]; r3 ^= F(st + 3 * Lane, l3) ^ st[3 * Lane + P + 15];
        l0 ^= F(st, r0) ^ st[P + 16]; l1 ^= F(st + 1 * Lane, r1) ^ st[1 * Lane + P + 16]; l2 ^= F(st + 2 * Lane, r2) ^ st[2 * Lane + P + 16]; l3 ^= F(st + 3 * Lane, r3) ^ st[3 * Lane + P + 16];
        xl0 = r0 ^ st[P + 17]; xr0 = l0; xl1 = r1 ^ st[1 * Lane + P + 17]; xr1 = l1; xl2 = r2 ^ st[2 * Lane + P + 17]; xr2 = l2; xl3 = r3 ^ st[3 * Lane + P + 17]; xr3 = l3;
    }
}
