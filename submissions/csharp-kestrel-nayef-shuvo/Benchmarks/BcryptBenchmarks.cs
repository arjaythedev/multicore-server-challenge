using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace Conduit.Benchmarks;

/// <summary>
/// The server's own bcrypt (BcryptCore: 1 to 4 hashes at once on one thread) against libcrypt and BCrypt.Net-Next.
/// Time per hash: the multi-lane methods run several hashes per call and divide. One hash is 25 to 75 ms, so this class
/// takes a few minutes even with BenchmarkDotNet's default settings.
/// </summary>
[MemoryDiagnoser]
[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
[CategoriesColumn]
public class BcryptBenchmarks
{
    private const string Password = "password123";
    private const string SeedHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
    private BcryptCore.Workspace _workspace = null!;
    private BcryptItem[][] _items = null!; // _items[n] = n+1 hashes

    [GlobalSetup]
    public void Setup()
    {
        _workspace = new BcryptCore.Workspace();
        _items = Enumerable.Range(1, BcryptCore.MaxLanes)
            .Select(n => Enumerable.Range(0, n).Select(_ => new BcryptItem
            {
                Password = System.Text.Encoding.UTF8.GetBytes(Password),
                Salt = System.Security.Cryptography.RandomNumberGenerator.GetBytes(16),
            }).ToArray()).ToArray();
    }

    [GlobalCleanup]
    public void Cleanup() => _workspace.Dispose();

    // ---------- verify (a login) ----------

    [Benchmark(Baseline = true), BenchmarkCategory("per hash")]
    public bool BCryptNet() => BCrypt.Net.BCrypt.Verify(Password, SeedHash);

    [Benchmark, BenchmarkCategory("per hash")]
    public bool Libcrypt() => LibcryptReference.Verify(Password, SeedHash);

    [Benchmark, BenchmarkCategory("per hash")]
    public void Core_1_hash() => BcryptCore.Compute(_workspace, 10, _items[0]);

    [Benchmark(OperationsPerInvoke = 2), BenchmarkCategory("per hash")]
    public void Core_2_hashes_at_once() => BcryptCore.Compute(_workspace, 10, _items[1]);

    [Benchmark(OperationsPerInvoke = 3), BenchmarkCategory("per hash")]
    public void Core_3_hashes_at_once() => BcryptCore.Compute(_workspace, 10, _items[2]);

    [Benchmark(OperationsPerInvoke = 4), BenchmarkCategory("per hash")]
    public void Core_4_hashes_at_once() => BcryptCore.Compute(_workspace, 10, _items[3]);
}
