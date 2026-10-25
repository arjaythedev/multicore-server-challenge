<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Infrastructure\Worker\Coroutines;
use App\Shared\Infrastructure\Worker\SurvivesRequests;
use Closure;
use ErrorException;
use PgSql\Connection;
use PgSql\Result;
use Swoole\Coroutine\System;
use Throwable;

/**
 * One Postgres connection of a worker. Statements are prepared on first use and executed by name; a broken
 * connection is dropped and reopened by the next call.
 */
#[SurvivesRequests(reason: 'Holds an open connection of the worker and the statements prepared on it.')]
final class PgLink
{
    /** Seconds a coroutine waits for the server's answer. */
    private const float ANSWER_TIMEOUT = 60.0;

    /** Applied to every connection when it is opened. */
    private const string SESSION_SETTINGS = "SET TimeZone = 'UTC'; SET plan_cache_mode = force_generic_plan; SET jit = off";

    /** Begin, commit and roll back, for a transaction and for one nested in it. */
    private const array OUTERMOST = ['BEGIN', 'COMMIT', 'ROLLBACK'];

    private const array NESTED = ['SAVEPOINT work', 'RELEASE SAVEPOINT work', 'ROLLBACK TO SAVEPOINT work'];

    private ?Connection $link = null;

    /** @var array<string, string> prepared statement name by SQL text */
    private array $statements = [];

    /** How many transaction() calls are running. */
    private int $transactionDepth = 0;

    public function __construct(
        private readonly string $databaseUrl,
    ) {
    }

    /**
     * Opens the connection if it is not open.
     *
     * @throws PgConnectionLostException when the server cannot be reached
     */
    public function connect(): void
    {
        $this->link ??= $this->open();
    }

    public function isOpen(): bool
    {
        return $this->link !== null;
    }

    public function close(): void
    {
        if ($this->link === null) {
            return;
        }

        pg_close($this->link);
        $this->link = null;
        $this->statements = [];
    }

    /**
     * Runs a statement that changes nothing. If the connection breaks it runs again on a new one, unless
     * a transaction is open.
     *
     * @param list<float|int|string|null> $params
     *
     * @throws PgConnectionLostException
     * @throws PgQueryFailedException
     */
    public function read(string $sql, array $params): Result
    {
        try {
            return $this->execute($sql, $params);
        } catch (PgConnectionLostException $lost) {
            if ($this->transactionDepth > 0) {
                throw $lost;
            }

            return $this->execute($sql, $params);
        }
    }

    /**
     * Runs a statement that changes data. Unlike read(), it is not run again once it has been sent, because
     * whether it took effect is unknown.
     *
     * @param list<float|int|string|null> $params
     *
     * @throws PgConnectionLostException
     * @throws PgQueryFailedException
     */
    public function write(string $sql, array $params): Result
    {
        try {
            return $this->execute($sql, $params);
        } catch (PgConnectionLostException $lost) {
            if ($lost->wasStatementSent() || $this->transactionDepth > 0) {
                throw $lost;
            }

            return $this->execute($sql, $params);
        }
    }

    /**
     * Runs $work in one transaction: committed when it returns, rolled back when it throws. Inside an open
     * transaction it runs in a savepoint.
     *
     * @template T
     *
     * @param Closure(): T $work
     *
     * @return T
     *
     * @throws PgConnectionLostException
     * @throws PgQueryFailedException
     */
    public function transaction(Closure $work): mixed
    {
        [$begin, $commit, $rollBack] = $this->isInTransaction() ? self::NESTED : self::OUTERMOST;

        $this->write($begin, []);
        ++$this->transactionDepth;

        try {
            $result = $work();
            $this->write($commit, []);

            return $result;
        } catch (Throwable $failure) {
            $this->rollBack($rollBack);

            throw $failure;
        } finally {
            --$this->transactionDepth;
        }
    }

    private function isInTransaction(): bool
    {
        return $this->transactionDepth > 0
            || ($this->link !== null && pg_transaction_status($this->link) !== PGSQL_TRANSACTION_IDLE);
    }

    /**
     * Undoes the open transaction; a connection that cannot is closed.
     */
    private function rollBack(string $rollBack): void
    {
        if ($this->link === null) {
            return;
        }

        try {
            $this->execute($rollBack, []);

            if ($rollBack === self::NESTED[2]) {
                $this->execute(self::NESTED[1], []);
            }
        } catch (PgException) {
            $this->close();
        }
    }

    /**
     * @param list<float|int|string|null> $params
     */
    private function execute(string $sql, array $params): Result
    {
        $link = $this->link ?? $this->reopen();
        $name = $this->statements[$sql] ?? $this->prepare($link, $sql);

        try {
            $sent = pg_send_execute($link, $name, $params);
        } catch (ErrorException $warning) {
            throw $this->discard($warning->getMessage(), false);
        }

        if (!$sent) {
            throw $this->discard('the statement could not be sent', false);
        }

        return $this->collect($link, true);
    }

    private function prepare(Connection $link, string $sql): string
    {
        $name = 's' . \count($this->statements);

        try {
            $sent = pg_send_prepare($link, $name, $sql);
        } catch (ErrorException $warning) {
            throw $this->discard($warning->getMessage(), false);
        }

        if (!$sent) {
            throw $this->discard('the statement could not be prepared', false);
        }

        $this->collect($link, false);
        $this->statements[$sql] = $name;

        return $name;
    }

    /**
     * The one result of the command just sent.
     */
    private function collect(Connection $link, bool $statementSent): Result
    {
        $this->awaitAnswer($link);
        $result = pg_get_result($link);

        if ($result === false) {
            throw $this->discard('the server returned no result', $statementSent);
        }

        $status = pg_result_status($result);

        // A command ends only when pg_get_result() has returned false.
        while (pg_get_result($link) !== false) {
        }

        if ($status === PGSQL_TUPLES_OK || $status === PGSQL_COMMAND_OK) {
            return $result;
        }

        if (pg_connection_status($link) === PGSQL_CONNECTION_BAD) {
            throw $this->discard((string) pg_result_error($result), $statementSent);
        }

        throw PgQueryFailedException::withSqlState(
            (string) pg_result_error_field($result, PGSQL_DIAG_SQLSTATE),
            (string) pg_result_error($result),
        );
    }

    /**
     * Inside a coroutine, waits for the answer while the other coroutines run.
     */
    private function awaitAnswer(Connection $link): void
    {
        if (!Coroutines::running()) {
            return;
        }

        $socket = pg_socket($link);

        // true until the whole answer has arrived
        while ($socket !== false && pg_connection_busy($link)) {
            if (System::waitEvent($socket, SWOOLE_EVENT_READ, self::ANSWER_TIMEOUT) === false) {
                return;
            }
        }
    }

    /**
     * Opens a new connection in place of a lost one, unless a transaction was open.
     */
    private function reopen(): Connection
    {
        if ($this->transactionDepth > 0) {
            throw PgConnectionLostException::because('the connection broke inside a transaction', false);
        }

        return $this->open();
    }

    private function open(): Connection
    {
        // pg_connect() reports a refused connection as a warning; turn it into an exception.
        set_error_handler(static function (int $severity, string $message): never {
            throw new ErrorException($message, 0, $severity);
        });

        try {
            $link = pg_connect($this->databaseUrl, PGSQL_CONNECT_FORCE_NEW);
            $settled = $link !== false && pg_query($link, self::SESSION_SETTINGS) !== false;
        } catch (ErrorException $warning) {
            throw PgConnectionLostException::because($warning->getMessage(), false);
        } finally {
            restore_error_handler();
        }

        if ($link === false || !$settled) {
            throw PgConnectionLostException::because('could not connect to the server', false);
        }

        $this->statements = [];

        return $this->link = $link;
    }

    private function discard(string $reason, bool $statementSent): PgConnectionLostException
    {
        if ($this->link !== null) {
            pg_close($this->link);
        }

        $this->link = null;
        $this->statements = [];

        return PgConnectionLostException::because($reason, $statementSent);
    }
}
