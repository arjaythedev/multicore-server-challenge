<?php

declare(strict_types=1);

use App\Kernel;
use App\Shared\Infrastructure\Server\ConnectionLimit;
use App\Shared\Infrastructure\Server\RequestHandler;
use App\Shared\Infrastructure\Worker\OpenWorkerConnections;
use App\Shared\Infrastructure\Worker\TaskWorkers;
use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Http\Server;

/*
 * The HTTP server: Swoole's event loop holds the connections and parses the requests, in worker processes that each
 * boot the kernel once. A coroutine that waits for Postgres lets the worker's other requests run (see PgConnection).
 */

require \dirname(__DIR__) . '/vendor/autoload.php';

$setting = static function (string $name): string {
    $value = getenv($name);

    if ($value === false || $value === '') {
        fwrite(STDERR, "$name is not set; run the server with start.sh\n");

        exit(1);
    }

    return $value;
};

// Requests between two collections of reference cycles.
const COLLECT_EVERY = 100;

// Every connection is an open file.
$openFiles = posix_getrlimit()['soft openfiles'] ?? 1024;

$server = new Server($setting('HOST'), (int) $setting('PORT'), SWOOLE_BASE);
$server->set([
    'worker_num' => (int) $setting('PHP_WORKERS'),
    // Workers are never recycled.
    'max_request' => 0,
    'enable_coroutine' => true,
    // No runtime hooks: Postgres is waited on directly.
    'hook_flags' => 0,
    // Each worker accepts on its own socket.
    'enable_reuse_port' => true,
    'max_connection' => ConnectionLimit::forOpenFiles($openFiles),
    'backlog' => 4096,
    // Users pause up to 70 s between pages.
    'heartbeat_idle_time' => 90,
    'heartbeat_check_interval' => 30,
    'open_tcp_nodelay' => true,
    'http_compression' => false,
    // The API reads JSON bodies and the Authorization header, and nothing from forms, files or cookies.
    'http_parse_post' => false,
    'http_parse_cookie' => false,
    'http_parse_files' => false,
    'log_level' => SWOOLE_LOG_WARNING,
    // Password hashing runs here (see TaskWorkers), one job at a time per task worker.
    'task_worker_num' => (int) $setting('PHP_TASK_WORKERS'),
    'task_enable_coroutine' => false,
    'task_max_request' => 0,
]);

$handler = null;

$server->on('workerStart', static function (Server $server) use (&$handler, $setting): void {
    // A task worker only runs jobs; it needs neither the kernel nor Postgres.
    if ($server->taskworker) {
        return;
    }

    $kernel = Kernel::fromContext(['APP_ENV' => $setting('APP_ENV'), 'APP_DEBUG' => $setting('APP_DEBUG')]);
    $kernel->boot();

    $container = $kernel->getContainer();
    $startup = $container->get(OpenWorkerConnections::class);
    \assert($startup instanceof OpenWorkerConnections);
    $startup();

    if ($server->setting['task_worker_num'] > 0) {
        $taskWorkers = $container->get(TaskWorkers::class);
        \assert($taskWorkers instanceof TaskWorkers);
        $taskWorkers->attach($server);
    }

    $http = $container->get('http_kernel');
    \assert($http instanceof \Symfony\Component\HttpKernel\HttpKernelInterface);
    $handler = new RequestHandler($http);
});

$server->on('task', static fn (Server $server, int $taskId, int $workerId, mixed $job): array => TaskWorkers::perform($job));

$crashed = false;

// A worker that dies stops the server, instead of Swoole's manager starting a new one in its place.
$server->on('workerError', static function (Server $server, int $workerId, int $workerPid, int $exitCode, int $signal) use (&$crashed): void {
    $crashed = true;
    fwrite(STDERR, "worker $workerId (pid $workerPid) died with exit code $exitCode, signal $signal; stopping the server\n");
    $server->shutdown();
});

$served = 0;

$server->on('request', static function (Request $request, Response $response) use (&$handler, &$served): void {
    // Nothing a request throws may end the worker.
    try {
        $reply = $handler->handle($request->server ?? [], $request->header ?? [], $request->get ?? [], (string) $request->rawContent());

        $response->status($reply->status);

        foreach ($reply->headers as [$name, $value]) {
            $response->header($name, $value);
        }

        $response->end($reply->body);
    } catch (Throwable $failure) {
        error_log((string) $failure);
    }

    if (++$served % COLLECT_EVERY === 0) {
        gc_collect_cycles();
    }
});

$server->start();

exit($crashed ? 1 : 0);
