<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Infrastructure\Server;

use PHPUnit\Framework\Attributes\RequiresOperatingSystem;
use PHPUnit\Framework\Attributes\RequiresPhpExtension;
use PHPUnit\Framework\TestCase;
use RuntimeException;

/**
 * The server as start.sh runs it: how long its workers live and how it stops.
 */
#[RequiresOperatingSystem('Linux')]
#[RequiresPhpExtension('posix')]
final class ServerProcessTest extends TestCase
{
    private const string ROOT = __DIR__ . '/../../../../..';

    /** @var resource|null */
    private $process;

    private int $port = 0;

    private string $log = '';

    public static function setUpBeforeClass(): void
    {
        // start.sh runs the production kernel, which build.sh compiles.
        exec('php ' . escapeshellarg(self::ROOT . '/bin/console') . ' cache:warmup --env=prod --no-debug 2>&1', $output, $code);
        if ($code !== 0) {
            throw new RuntimeException('cache:warmup failed: ' . implode("\n", $output));
        }
    }

    protected function tearDown(): void
    {
        if (\is_resource($this->process)) {
            $pid = proc_get_status($this->process)['pid'];
            posix_kill($pid, \SIGTERM);
            $this->waitForExit(5.0);
            foreach ($this->descendants($pid) as $child) {
                posix_kill($child, \SIGKILL);
            }
            proc_close($this->process);
        }
        if ($this->log !== '' && is_file($this->log)) {
            unlink($this->log);
        }
    }

    public function testAWorkerKeepsThousandsOfIdleConnectionsOpen(): void
    {
        $connections = 5000;
        // This process and the server (start.sh raises its soft limit to the hard one) each need a file per connection.
        $hard = posix_getrlimit()['hard openfiles'] ?? 0;
        $hard = $hard === 'unlimited' ? 1 << 20 : (int) $hard;
        if ($hard < 2 * $connections || !posix_setrlimit(\POSIX_RLIMIT_NOFILE, $connections + 200, $hard)) {
            self::markTestSkipped("this process may open only $hard files");
        }

        $this->start(workers: 1);
        $processes = $this->workers();

        $open = [];
        for ($i = 0; $i < $connections; ++$i) {
            $socket = $this->connect();
            self::assertSame(404, $this->send($socket, '/api/nothing-here'));
            $open[] = $socket;
        }

        self::assertSame($processes, $this->workers(), 'No worker died and none was started in its place.');
        self::assertSame(200, $this->send($open[0], '/api/tags'), 'An old connection still gets answers.');
        self::assertStringNotContainsString('died', (string) file_get_contents($this->log));
    }

    public function testAWorkerThatDiesStopsTheServer(): void
    {
        $this->start(workers: 2);

        posix_kill($this->workers()[0], \SIGKILL);

        self::assertSame(1, $this->waitForExit(10.0), 'start.sh reports the crash.');
        self::assertStringContainsString('stopping the server', (string) file_get_contents($this->log));
    }

    public function testAStopRequestEndsTheServerCleanly(): void
    {
        $this->start(workers: 2);
        \assert(\is_resource($this->process));

        posix_kill(proc_get_status($this->process)['pid'], \SIGTERM);

        self::assertSame(0, $this->waitForExit(10.0));
    }

    private function start(int $workers, int $taskWorkers = 2): void
    {
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        \assert($probe !== false);
        $this->port = (int) substr((string) strrchr((string) stream_socket_get_name($probe, false), ':'), 1);
        fclose($probe);

        $this->log = (string) tempnam(sys_get_temp_dir(), 'server-');
        $environment = [
            'PATH' => (string) getenv('PATH'),
            'DATABASE_URL' => \is_string($_SERVER['DATABASE_URL'] ?? null) ? $_SERVER['DATABASE_URL'] : '',
            'JWT_SECRET' => 'multicore-server-challenge',
            'HOST' => '127.0.0.1',
            'PORT' => (string) $this->port,
            'PHP_WORKERS' => (string) $workers,
            'PG_CONNECTIONS' => '1',
            'PHP_TASK_WORKERS' => (string) $taskWorkers,
        ];
        $process = proc_open(['bash', self::ROOT . '/start.sh'], [0 => ['file', '/dev/null', 'r'], 1 => ['file', $this->log, 'a'], 2 => ['file', $this->log, 'a']], $pipes, null, $environment);
        \assert(\is_resource($process));
        $this->process = $process;

        for ($i = 0; $i < 100; ++$i) {
            $socket = @stream_socket_client('tcp://127.0.0.1:' . $this->port, timeout: 1);
            if ($socket !== false && \count($this->workers()) === $workers + $taskWorkers) {
                fclose($socket);

                return;
            }
            usleep(100_000);
        }

        throw new RuntimeException('The server did not start: ' . file_get_contents($this->log));
    }

    /**
     * @return resource
     */
    private function connect()
    {
        $socket = stream_socket_client('tcp://127.0.0.1:' . $this->port, $errno, $error, 5);
        if ($socket === false) {
            throw new RuntimeException("connect failed: $error");
        }

        return $socket;
    }

    /**
     * Sends one keep-alive GET and returns the status of its response.
     *
     * @param resource $socket
     */
    private function send($socket, string $path): int
    {
        fwrite($socket, "GET $path HTTP/1.1\r\nHost: localhost\r\n\r\n");
        $head = '';
        while (!str_contains($head, "\r\n\r\n") && !feof($socket)) {
            $head .= (string) fread($socket, 8192);
        }
        preg_match('/^HTTP\/1\.1 (\d{3})/', $head, $status);
        preg_match('/content-length: (\d+)/i', $head, $length);
        $body = \strlen(substr($head, (int) strpos($head, "\r\n\r\n") + 4));
        while ($body < (int) ($length[1] ?? 0)) {
            $body += \strlen((string) fread($socket, 8192));
        }

        return (int) ($status[1] ?? 0);
    }

    /**
     * The worker and task worker processes: the children of the php process start.sh runs, or that process itself when
     * Swoole runs a single worker without forking.
     *
     * @return list<int>
     */
    private function workers(): array
    {
        \assert(\is_resource($this->process));
        $server = $this->children(proc_get_status($this->process)['pid']);
        if ($server === []) {
            return [];
        }

        return $this->children($server[0]) ?: [$server[0]];
    }

    /**
     * @return list<int>
     */
    private function descendants(int $pid): array
    {
        $all = [];
        foreach ($this->children($pid) as $child) {
            $all = [...$all, $child, ...$this->descendants($child)];
        }

        return $all;
    }

    /**
     * @return list<int>
     */
    private function children(int $parent): array
    {
        $children = [];
        foreach (glob('/proc/[0-9]*/stat') ?: [] as $file) {
            $stat = (string) @file_get_contents($file);
            // after "pid (name) ", the fields are: state, parent pid, ...
            $fields = explode(' ', substr($stat, (int) strrpos($stat, ')') + 2));
            if ((int) ($fields[1] ?? 0) === $parent) {
                $children[] = (int) basename(\dirname($file));
            }
        }
        sort($children);

        return $children;
    }

    /**
     * Waits for start.sh to exit and returns its exit code, or null if it still runs.
     */
    private function waitForExit(float $seconds): ?int
    {
        \assert(\is_resource($this->process));
        $deadline = microtime(true) + $seconds;
        do {
            $status = proc_get_status($this->process);
            if (!$status['running']) {
                return $status['exitcode'];
            }
            usleep(50_000);
        } while (microtime(true) < $deadline);

        return null;
    }
}
