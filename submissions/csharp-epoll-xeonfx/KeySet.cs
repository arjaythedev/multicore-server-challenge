using System;
using System.Buffers.Binary;

/// <summary>
/// Distinct byte keys, numbered 1, 2, ... in the order first added: a batch's slugs, usernames, pages or (viewer,
/// article) pairs, each read once however many requests ask for it. Open addressing over one byte arena; cleared
/// between batches without freeing anything.
/// </summary>
sealed class KeySet
{
    byte[] _bytes = new byte[4096];
    int _used;
    int[] _start = new int[64], _length = new int[64], _hash = new int[64];
    /// <summary>Slots hold an ordinal, 0 when empty; the table stays at most half full.</summary>
    int[] _table = new int[128];
    byte[] _scratch = new byte[256];

    /// <summary>How many distinct keys; ordinals run from 1 to Count.</summary>
    public int Count { get; private set; }

    public ReadOnlySpan<byte> this[int ordinal] => _bytes.AsSpan(_start[ordinal - 1], _length[ordinal - 1]);

    /// <summary>The key's ordinal, adding it if new; <paramref name="added"/> says which.</summary>
    public int Add(ReadOnlySpan<byte> key, out bool added)
    {
        int hash = Hash(key);
        int mask = _table.Length - 1;
        for (int slot = hash & mask; ; slot = (slot + 1) & mask)
        {
            int o = _table[slot];
            if (o == 0)
            {
                added = true;
                return Insert(key, hash, slot);
            }
            if (_hash[o - 1] == hash && this[o].SequenceEqual(key))
            {
                added = false;
                return o;
            }
        }
    }

    public int Add(ReadOnlySpan<byte> key) => Add(key, out _);

    /// <summary>The key's ordinal, or 0 when it isn't in the set.</summary>
    public int Find(ReadOnlySpan<byte> key)
    {
        int hash = Hash(key);
        int mask = _table.Length - 1;
        for (int slot = hash & mask; ; slot = (slot + 1) & mask)
        {
            int o = _table[slot];
            if (o == 0) return 0;
            if (_hash[o - 1] == hash && this[o].SequenceEqual(key)) return o;
        }
    }

    // keys of one, two or three numbers, as most of a batch's keys are
    public int Add(long a) { Span<byte> k = stackalloc byte[8]; Put(k, a, 0, 0, 1); return Add(k); }
    public int Find(long a) { Span<byte> k = stackalloc byte[8]; Put(k, a, 0, 0, 1); return Find(k); }
    public int Add(long a, long b, out bool added) { Span<byte> k = stackalloc byte[16]; Put(k, a, b, 0, 2); return Add(k, out added); }
    public int Find(long a, long b) { Span<byte> k = stackalloc byte[16]; Put(k, a, b, 0, 2); return Find(k); }
    public int Add(long a, long b, long c) { Span<byte> k = stackalloc byte[24]; Put(k, a, b, c, 3); return Add(k); }

    static void Put(Span<byte> k, long a, long b, long c, int n)
    {
        BinaryPrimitives.WriteInt64LittleEndian(k, a);
        if (n > 1) BinaryPrimitives.WriteInt64LittleEndian(k[8..], b);
        if (n > 2) BinaryPrimitives.WriteInt64LittleEndian(k[16..], c);
    }

    /// <summary>The <paramref name="i"/>th number of a key made of numbers.</summary>
    public long Number(int ordinal, int i) => BinaryPrimitives.ReadInt64LittleEndian(this[ordinal][(8 * i)..]);

    /// <summary>A name followed by numbers (a page of a tag, say): the name.</summary>
    public ReadOnlySpan<byte> Name(int ordinal, int numbers) { var k = this[ordinal]; return k[..(k.Length - 8 * numbers)]; }

    /// <summary>A name followed by numbers: the <paramref name="i"/>th number.</summary>
    public long Tail(int ordinal, int numbers, int i)
    {
        var k = this[ordinal];
        return BinaryPrimitives.ReadInt64LittleEndian(k[(k.Length - 8 * numbers + 8 * i)..]);
    }

    /// <summary>Adds a name followed by numbers.</summary>
    public int Add(ReadOnlySpan<byte> name, long a, long b)
    {
        int n = name.Length + 16;
        if (_scratch.Length < n) _scratch = new byte[Math.Max(n, 2 * _scratch.Length)];
        Span<byte> k = _scratch.AsSpan(0, n);
        name.CopyTo(k);
        Put(k[name.Length..], a, b, 0, 2);
        return Add(k);
    }

    public void Clear()
    {
        if (Count == 0) return;
        Array.Clear(_table);
        Count = 0;
        _used = 0;
    }

    int Insert(ReadOnlySpan<byte> key, int hash, int slot)
    {
        if (_bytes.Length - _used < key.Length) Array.Resize(ref _bytes, Math.Max(_bytes.Length * 2, _used + key.Length));
        if (Count == _start.Length)
        {
            Array.Resize(ref _start, Count * 2);
            Array.Resize(ref _length, Count * 2);
            Array.Resize(ref _hash, Count * 2);
        }
        key.CopyTo(_bytes.AsSpan(_used));
        _start[Count] = _used;
        _length[Count] = key.Length;
        _hash[Count] = hash;
        _used += key.Length;
        int ordinal = ++Count;
        _table[slot] = ordinal;
        if (2 * Count > _table.Length) Grow();
        return ordinal;
    }

    void Grow()
    {
        _table = new int[_table.Length * 2];
        int mask = _table.Length - 1;
        for (int o = 1; o <= Count; o++)
        {
            int slot = _hash[o - 1] & mask;
            while (_table[slot] != 0) slot = (slot + 1) & mask;
            _table[slot] = o;
        }
    }

    static int Hash(ReadOnlySpan<byte> key)
    {
        var h = new HashCode();
        h.AddBytes(key);
        return h.ToHashCode();
    }
}
