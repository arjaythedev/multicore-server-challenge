namespace Conduit.Dispatch;

/// <summary>A FIFO of jobs (read or write) that can also take jobs back at the front (for retries). Not thread-safe; the dispatcher locks around it.</summary>
internal sealed class JobQueue<T> where T : class {
    /// <summary>Ring buffer. Its length is always a power of two.</summary>
    private T[] _items = new T[64];
    /// <summary>Index of the oldest job.</summary>
    private int _head;

    /// <summary>Number of waiting jobs.</summary>
    public int Count { get; private set; }

    /// <summary>The oldest job. Call only when <see cref="Count"/> is above 0.</summary>
    public T Peek() => _items[_head];

    /// <summary>Adds a job at the back.</summary>
    public void PushBack(T job) {
        if (Count == _items.Length) {
            Grow();
        }

        _items[(_head + Count) & (_items.Length - 1)] = job;
        Count++;
    }

    /// <summary>Puts a job back at the front.</summary>
    public void PushFront(T job) {
        if (Count == _items.Length) {
            Grow();
        }

        _head = (_head - 1) & (_items.Length - 1);
        _items[_head] = job;
        Count++;
    }

    /// <summary>Removes and returns the oldest job.</summary>
    public T PopFront() {
        T job = _items[_head];
        _items[_head] = null!;
        _head = (_head + 1) & (_items.Length - 1);
        Count--;
        return job;
    }

    /// <summary>Doubles the ring and lays the jobs out from index 0. Capacity stays a power of two so indexes wrap with a mask.</summary>
    private void Grow() {
        T[] bigger = new T[_items.Length * 2];
        for (int i = 0; i < Count; i++) {
            bigger[i] = _items[(_head + i) & (_items.Length - 1)];
        }

        _items = bigger;
        _head = 0;
    }
}
