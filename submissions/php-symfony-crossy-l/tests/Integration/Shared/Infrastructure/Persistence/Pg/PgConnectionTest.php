<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Shared\Infrastructure\Persistence\Pg\PgConnectionLostException;
use App\Shared\Infrastructure\Persistence\Pg\PgQueryFailedException;
use PgSql\Connection;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class PgConnectionTest extends TestCase
{
    private PgConnection $connection;

    protected function setUp(): void
    {
        $this->connection = new PgConnection(self::databaseUrl(), 1);
    }

    protected function tearDown(): void
    {
        $this->connection->close();
    }

    public function testIsClosedUntilUsedAndThenStaysOpen(): void
    {
        self::assertFalse($this->connection->isOpen());

        $this->connection->read('SELECT 1', []);

        self::assertTrue($this->connection->isOpen());
    }

    public function testConnectOpensItAheadOfTheFirstStatement(): void
    {
        $this->connection->connect();

        self::assertTrue($this->connection->isOpen());
    }

    public function testReadReturnsTheRowsOfAParameterisedStatement(): void
    {
        $result = $this->connection->read('SELECT $1::int + $2::int AS total, $3::text AS word', [2, 3, 'x']);

        self::assertSame(['total' => '5', 'word' => 'x'], pg_fetch_assoc($result));
    }

    public function testTheSessionRunsInUtc(): void
    {
        $result = $this->connection->read("SELECT current_setting('TimeZone')", []);

        self::assertSame('UTC', pg_fetch_result($result, 0, 0));
    }

    public function testTheSessionKeepsGenericPlansAndNeverCompilesJit(): void
    {
        $setting = fn (string $name): mixed => pg_fetch_result($this->connection->read('SELECT current_setting($1)', [$name]), 0, 0);

        self::assertSame('force_generic_plan', $setting('plan_cache_mode'));
        self::assertSame('off', $setting('jit'));
    }

    public function testAStatementWithALimitParameterIsPlannedOnceAndNotOnEveryRun(): void
    {
        $sql = 'SELECT n FROM generate_series(1, 100) AS n ORDER BY n DESC LIMIT $1';

        for ($limit = 1; $limit <= 12; ++$limit) {
            $this->connection->read($sql, [$limit]);
        }

        $plans = pg_fetch_assoc($this->connection->read(
            'SELECT custom_plans, generic_plans FROM pg_prepared_statements WHERE statement LIKE $1',
            ['%generate_series%'],
        ));

        self::assertSame(['custom_plans' => '0', 'generic_plans' => '12'], $plans);
    }

    public function testAStatementIsPreparedOnceAndExecutedByNameAfterwards(): void
    {
        $pid = $this->backendPid();

        $this->connection->read('SELECT $1::int', [1]);
        $this->connection->read('SELECT $1::int', [2]);
        $this->connection->read('SELECT $1::int', [3]);

        $prepared = pg_fetch_result(
            $this->connection->read('SELECT count(*) FROM pg_prepared_statements WHERE statement = $1', ['SELECT $1::int']),
            0,
            0,
        );
        self::assertSame('1', $prepared, 'three runs share one prepared statement');
        self::assertSame($pid, $this->backendPid(), 'the same backend served every call');
    }

    public function testAWriteReportsTheSqlStateOfAUniqueViolation(): void
    {
        $this->connection->write('BEGIN', []);
        $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['pg-connection-test-duplicate']);

        try {
            $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['pg-connection-test-duplicate']);
            self::fail('the second insert should have been refused');
        } catch (PgQueryFailedException $failure) {
            self::assertSame('23505', $failure->getSqlState());
            self::assertTrue($failure->isUniqueViolation());
        } finally {
            $this->connection->write('ROLLBACK', []);
        }
    }

    public function testAStatementThatFailsLeavesTheConnectionUsable(): void
    {
        $pid = $this->backendPid();

        try {
            $this->connection->read('SELECT 1 / $1::int', [0]);
            self::fail('division by zero should have been refused');
        } catch (PgQueryFailedException $failure) {
            self::assertSame('22012', $failure->getSqlState());
        }

        self::assertSame($pid, $this->backendPid());
    }

    public function testReconnectsAndPreparesAgainWhenTheServerEndsTheSession(): void
    {
        $first = $this->backendPid();
        $this->connection->read('SELECT $1::int', [1]);

        $this->terminateBackend($first);

        // The next read finds the connection dead, opens another and runs on it.
        $result = $this->connection->read('SELECT $1::int AS n', [7]);

        self::assertSame('7', pg_fetch_result($result, 0, 0));
        self::assertNotSame($first, $this->backendPid());
    }

    public function testAWriteAfterTheSessionEndedIsNeverRunTwice(): void
    {
        $first = $this->backendPid();
        $this->terminateBackend($first);

        try {
            $this->connection->write('SELECT pg_backend_pid()', []);
            self::fail('the broken connection should have been reported');
        } catch (PgConnectionLostException $lost) {
            self::assertTrue($lost->wasStatementSent());
        }

        // The failure dropped the connection; the call after it opens a new one.
        self::assertNotSame($first, $this->backendPid());
    }

    public function testConnectingToAServerThatIsNotThereIsReportedNotThrownAsAWarning(): void
    {
        $connection = new PgConnection('postgres://conduit:conduit@127.0.0.1:1/nothing', 1);

        $this->expectException(PgConnectionLostException::class);
        $connection->connect();
    }

    public function testTransactionRollsBackWritesAndLeavesTheNextRequestUsable(): void
    {
        try {
            $this->connection->transaction(function (): void {
                $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['transaction-rollback']);

                throw new RuntimeException('request failed');
            });
            self::fail('the request failure must reach the caller');
        } catch (RuntimeException $failure) {
            self::assertSame('request failed', $failure->getMessage());
        }

        self::assertSame('0', pg_fetch_result($this->connection->read('SELECT count(*) FROM tags WHERE name = $1', ['transaction-rollback']), 0, 0));
    }

    public function testTransactionCommitsBeforeReturningToTheCaller(): void
    {
        $observer = new PgConnection(self::databaseUrl(), 1);
        $count = static fn (PgConnection $connection): string => (string) pg_fetch_result(
            $connection->read('SELECT count(*) FROM tags WHERE name = $1', ['transaction-commit']),
            0,
            0,
        );

        try {
            $returned = $this->connection->transaction(function () use ($observer, $count): int {
                $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['transaction-commit']);
                self::assertSame('0', $count($observer));

                return 42;
            });

            self::assertSame(42, $returned);
            self::assertSame('1', $count($observer));
        } finally {
            $observer->write('DELETE FROM tags WHERE name = $1', ['transaction-commit']);
            $observer->close();
        }
    }

    public function testSqlFailureInsideATransactionIsRolledBack(): void
    {
        try {
            $this->connection->transaction(function (): void {
                $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['transaction-sql-failure']);
                $this->connection->read('SELECT 1 / $1::int', [0]);
            });
            self::fail('the SQL failure must reach the caller');
        } catch (PgQueryFailedException $failure) {
            self::assertSame('22012', $failure->getSqlState());
        }

        self::assertSame('0', pg_fetch_result($this->connection->read('SELECT count(*) FROM tags WHERE name = $1', ['transaction-sql-failure']), 0, 0));
    }

    public function testNestedRollbackDoesNotHideTheEnclosingSavepoint(): void
    {
        $this->connection->write('BEGIN', []);

        try {
            try {
                $this->connection->transaction(function (): void {
                    $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['outer-savepoint']);

                    try {
                        $this->connection->transaction(static function (): void {
                            throw new RuntimeException('inner failure');
                        });
                    } catch (RuntimeException) {
                    }

                    throw new RuntimeException('outer failure');
                });
            } catch (RuntimeException $failure) {
                self::assertSame('outer failure', $failure->getMessage());
            }

            self::assertSame('0', pg_fetch_result($this->connection->read('SELECT count(*) FROM tags WHERE name = $1', ['outer-savepoint']), 0, 0));
        } finally {
            $this->connection->write('ROLLBACK', []);
        }
    }

    public function testLosingAConnectionInsideATransactionDoesNotReconnectUntilItUnwinds(): void
    {
        $first = $this->backendPid();

        try {
            $this->connection->transaction(function () use ($first): void {
                $this->terminateBackend($first);
                $this->connection->read('SELECT $1::int', [7]);
            });
            self::fail('the transaction cannot continue on a new connection');
        } catch (PgConnectionLostException) {
            self::assertFalse($this->connection->isOpen());
        }

        self::assertNotSame($first, $this->backendPid());
    }

    private function backendPid(): int
    {
        return (int) pg_fetch_result($this->connection->read('SELECT pg_backend_pid()', []), 0, 0);
    }

    private function terminateBackend(int $pid): void
    {
        $other = pg_connect(self::databaseUrl(), PGSQL_CONNECT_FORCE_NEW);
        self::assertInstanceOf(Connection::class, $other);
        // With a timeout the call returns once the session is gone, so the next statement cannot race it.
        pg_query_params($other, 'SELECT pg_terminate_backend($1, 5000)', [$pid]);
        pg_close($other);
    }

    private static function databaseUrl(): string
    {
        $url = $_SERVER['DATABASE_URL'] ?? null;
        self::assertIsString($url);

        return $url;
    }
}
