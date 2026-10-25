<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Tests\Support\RunsCoroutines;
use PHPUnit\Framework\Attributes\RequiresPhpExtension;
use PHPUnit\Framework\TestCase;
use Swoole\Coroutine;
use Swoole\Coroutine\WaitGroup;
use Throwable;

/**
 * The connection pool inside Swoole's coroutines: a coroutine that waits for Postgres lets the others run, and a
 * transaction keeps one connection for all of its statements.
 */
#[RequiresPhpExtension('swoole')]
final class PgConnectionPoolTest extends TestCase
{
    use RunsCoroutines;

    public function testWaitingForPostgresDoesNotHoldUpTheOtherCoroutines(): void
    {
        $ticks = 0;
        $connection = new PgConnection(self::databaseUrl(), 1);

        $this->inCoroutines(function () use (&$ticks, $connection): void {
            $stop = false;
            Coroutine::create(static function () use (&$ticks, &$stop): void {
                while (!$stop) {
                    ++$ticks;
                    Coroutine::sleep(0.01);
                }
            });

            $connection->read('SELECT pg_sleep(0.3)', []);
            $stop = true;
        });

        // a ticker every 10 ms ticks about 30 times in 300 ms; a worker held up by the wait would tick once
        self::assertGreaterThan(15, $ticks);
    }

    public function testStatementsOfManyCoroutinesShareTheConnectionsOneAtATime(): void
    {
        $connection = new PgConnection(self::databaseUrl(), 2);
        $answers = [];
        $started = microtime(true);

        $this->inCoroutines(function () use ($connection, &$answers): void {
            $group = new WaitGroup();

            for ($number = 1; $number <= 6; ++$number) {
                $group->add();
                Coroutine::create(static function () use ($connection, $number, $group, &$answers): void {
                    $result = $connection->read('SELECT pg_sleep(0.2), $1::int', [$number]);
                    $answers[] = (int) pg_fetch_result($result, 0, 1);
                    $group->done();
                });
            }

            $group->wait();
        });

        $elapsed = microtime(true) - $started;
        sort($answers);

        self::assertSame([1, 2, 3, 4, 5, 6], $answers, 'Every coroutine got its own answer.');
        // six statements of 0.2 s on two connections take 0.6 s; one after another would take 1.2 s
        self::assertGreaterThan(0.5, $elapsed);
        self::assertLessThan(1.0, $elapsed);
    }

    public function testATransactionKeepsOneConnectionForAllItsStatements(): void
    {
        $connection = new PgConnection(self::databaseUrl(), 3);
        $processes = [];

        $this->inCoroutines(function () use ($connection, &$processes): void {
            $group = new WaitGroup();

            for ($number = 0; $number < 3; ++$number) {
                $group->add();
                Coroutine::create(static function () use ($connection, $number, $group, &$processes): void {
                    $connection->transaction(static function () use ($connection, $number, &$processes): void {
                        $first = (int) pg_fetch_result($connection->read('SELECT pg_backend_pid()', []), 0, 0);
                        $connection->read('SELECT pg_sleep(0.05)', []);
                        $second = (int) pg_fetch_result($connection->read('SELECT pg_backend_pid()', []), 0, 0);
                        $processes[$number] = [$first, $second];
                    });
                    $group->done();
                });
            }

            $group->wait();
        });

        foreach ($processes as [$first, $second]) {
            self::assertSame($first, $second, 'A transaction runs all its statements on one connection.');
        }

        self::assertCount(3, array_unique(array_column($processes, 0)), 'Three transactions at once hold three connections.');
    }

    public function testAConnectionIsGivenBackWhenAStatementFails(): void
    {
        $connection = new PgConnection(self::databaseUrl(), 1);
        $failures = 0;
        $answer = null;

        $this->inCoroutines(function () use ($connection, &$failures, &$answer): void {
            try {
                $connection->read('SELECT * FROM a_table_that_is_not_there', []);
            } catch (Throwable) {
                ++$failures;
            }

            $answer = pg_fetch_result($connection->read('SELECT 7', []), 0, 0);
        });

        self::assertSame(1, $failures);
        self::assertSame('7', $answer, 'The only connection was given back, so the next statement ran.');
    }
}
