<?php

declare(strict_types=1);

namespace App\Tests\Support;

use RuntimeException;
use Swoole\Coroutine;

use function Swoole\Coroutine\run;

use Throwable;

/**
 * For tests that need the worker's own setting: Swoole's coroutines, and the database the integration tests use.
 */
trait RunsCoroutines
{
    public static function setUpBeforeClass(): void
    {
        // As in the server, no runtime hooks: this build of PHP has no curl for them to wrap.
        Coroutine::set(['hook_flags' => 0]);
    }

    /**
     * Runs $body in a coroutine and finishes when it and everything it started have. What it throws is thrown here.
     */
    private function inCoroutines(callable $body): void
    {
        $failure = null;

        run(static function () use ($body, &$failure): void {
            try {
                $body();
            } catch (Throwable $thrown) {
                $failure = $thrown;
            }
        });

        if ($failure !== null) {
            throw new RuntimeException('A coroutine failed: ' . $failure->getMessage(), 0, $failure);
        }
    }

    private static function databaseUrl(): string
    {
        $url = $_SERVER['DATABASE_URL'] ?? null;

        return \is_string($url) ? $url : 'postgres://conduit:conduit@127.0.0.1:5432/conduit_phpunit';
    }
}
