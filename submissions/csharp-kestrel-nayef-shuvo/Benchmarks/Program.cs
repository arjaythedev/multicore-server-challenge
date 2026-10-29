using BenchmarkDotNet.Running;

namespace Conduit.Benchmarks;

public static class Program
{
    // bash Benchmarks/run.sh passes the arguments through to BenchmarkDotNet (--filter, --list, --job, ...).
    public static int Main(string[] args)
    {
        if (args.Contains("--check")) return BcryptCrossCheck.Run(); // bash Benchmarks/run.sh --check
        BenchmarkSwitcher.FromAssembly(typeof(Program).Assembly).Run(args);
        return 0;
    }
}
