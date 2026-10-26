using BenchmarkDotNet.Running;

BenchmarkSwitcher.FromAssembly(typeof(Conduit.Benchmarks.BcryptBenchmarks).Assembly).Run(args);
