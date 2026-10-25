<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\Batch\PendingRead;
use App\Shared\Infrastructure\Persistence\Pg\Batch\PendingReads;
use App\Shared\Infrastructure\Worker\Coroutines;
use App\Shared\Infrastructure\Worker\SurvivesRequests;
use Closure;
use PgSql\Result;
use Swoole\Coroutine;
use Swoole\Coroutine\Channel;
use Throwable;

/**
 * The worker's connections to Postgres, as one object for the repositories. A statement runs on a free connection;
 * a transaction keeps one for all of its statements. A read that finds every connection busy joins the reads waiting,
 * and the next connection to come free serves them, those of one batched read in one statement.
 */
#[SurvivesRequests(reason: 'Holds the worker\'s open connections and the statements prepared on them.')]
class PgConnection
{
    /** The coroutine context key of the connection a coroutine holds. */
    private const string LEASED = 'pg.link';

    /** @var list<PgLink> */
    private array $links = [];

    /** The free connections, made when first needed. */
    private ?Channel $free = null;

    private readonly PendingReads $pending;

    public function __construct(
        string $databaseUrl,
        int $size,
    ) {
        $this->pending = new PendingReads();

        for ($count = 0; $count < max(1, $size); ++$count) {
            $this->links[] = new PgLink($databaseUrl);
        }
    }

    /**
     * Opens every connection ahead of the first statement.
     *
     * @throws PgConnectionLostException when the server cannot be reached
     */
    public function connect(): void
    {
        foreach ($this->links as $link) {
            $link->connect();
        }
    }

    public function isOpen(): bool
    {
        foreach ($this->links as $link) {
            if ($link->isOpen()) {
                return true;
            }
        }

        return false;
    }

    public function close(): void
    {
        foreach ($this->links as $link) {
            $link->close();
        }
    }

    /**
     * @param list<float|int|string|null> $params
     *
     * @throws PgConnectionLostException
     * @throws PgQueryFailedException
     */
    public function read(string $sql, array $params): Result
    {
        $answer = $this->queued($sql, null, $params);
        \assert($answer instanceof Result);

        return $answer;
    }

    /**
     * Runs a read that may share a statement with other requests' reads; returns this request's rows.
     *
     * @param list<float|int|string> $params
     *
     * @return list<array<array-key, string|null>>
     *
     * @throws PgConnectionLostException
     * @throws PgQueryFailedException
     */
    public function readBatched(BatchedRead $read, array $params): array
    {
        $answer = $this->queued($read->sql, $read, $params);
        \assert(\is_array($answer));

        return $answer;
    }

    /**
     * @param list<float|int|string|null> $params
     *
     * @throws PgConnectionLostException
     * @throws PgQueryFailedException
     */
    public function write(string $sql, array $params): Result
    {
        return $this->leased(static fn (PgLink $link): Result => $link->write($sql, $params));
    }

    /**
     * Runs $work in one transaction on one connection.
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
        return $this->leased(static fn (PgLink $link): mixed => $link->transaction($work));
    }

    /**
     * @template T
     *
     * @param Closure(PgLink): T $work
     *
     * @return T
     */
    private function leased(Closure $work): mixed
    {
        if (!Coroutines::running()) {
            return $work($this->links[0]);
        }

        $context = Coroutine::getContext();

        if (isset($context[self::LEASED])) {
            $held = $context[self::LEASED];
            \assert($held instanceof PgLink);

            return $work($held);
        }

        $link = $this->free()->pop();
        \assert($link instanceof PgLink);
        $context[self::LEASED] = $link;

        try {
            return $work($link);
        } finally {
            unset($context[self::LEASED]);
            $this->release($link);
        }
    }

    /**
     * @param list<float|int|string|null> $params
     *
     * @return Result|list<array<array-key, string|null>>
     */
    private function queued(string $sql, ?BatchedRead $batched, array $params): Result|array
    {
        if (!Coroutines::running()) {
            return self::serveOne($this->links[0], $sql, $batched, $params);
        }

        $held = Coroutine::getContext()[self::LEASED] ?? null;

        if ($held instanceof PgLink) {
            return self::serveOne($held, $sql, $batched, $params);
        }

        $free = $this->free();

        if ($this->pending->isEmpty() && $free->length() > 0) {
            $link = $free->pop();
            \assert($link instanceof PgLink);

            try {
                return self::serveOne($link, $sql, $batched, $params);
            } finally {
                $this->release($link);
            }
        }

        $reply = new Channel(1);
        $this->pending->add(new PendingRead($sql, $batched, $params, $reply));
        $answer = $reply->pop();

        if ($answer instanceof Throwable) {
            throw $answer;
        }

        /** @var Result|list<array<array-key, string|null>> $answer */
        return $answer;
    }

    /**
     * Gives a connection to a coroutine waiting to change data, else to the waiting reads, else back to the free ones.
     */
    private function release(PgLink $link): void
    {
        $free = $this->free();

        if (!$this->pending->isEmpty() && $free->stats()['consumer_num'] === 0) {
            Coroutine::create($this->serveWaiting(...), $link);

            return;
        }

        $free->push($link);
    }

    /**
     * Serves the waiting reads on $link until none are left or a coroutine needs a connection to change data.
     */
    private function serveWaiting(PgLink $link): void
    {
        do {
            $this->serveBatch($link, $this->pending->takeOldest());
        } while (!$this->pending->isEmpty() && $this->free()->stats()['consumer_num'] === 0);

        $this->free()->push($link);
    }

    /**
     * Runs the reads of one statement and answers each coroutine; a failure is the answer, not thrown.
     *
     * @param non-empty-list<PendingRead> $reads
     */
    private function serveBatch(PgLink $link, array $reads): void
    {
        $batched = $reads[0]->batched;

        if ($batched === null) {
            foreach ($reads as $read) {
                $read->reply->push(self::plainAnswer($link, $read));
            }

            return;
        }

        foreach ($this->batchAnswers($link, $batched, $reads) as $position => $answer) {
            $reads[$position]->reply->push($answer);
        }
    }

    private static function plainAnswer(PgLink $link, PendingRead $read): Result|Throwable
    {
        try {
            return $link->read($read->sql, $read->params);
        } catch (Throwable $failure) {
            return $failure;
        }
    }

    /**
     * @param non-empty-list<PendingRead> $reads
     *
     * @return list<list<array<array-key, string|null>>|Throwable>
     */
    private function batchAnswers(PgLink $link, BatchedRead $batched, array $reads): array
    {
        try {
            return self::rowsOfEach($link, $batched, array_map(static fn (PendingRead $read): array => $read->params, $reads));
        } catch (PgQueryFailedException $failure) {
            if (\count($reads) === 1) {
                return [$failure];
            }

            // Run each alone, so that only the request at fault is told.
            return array_map(fn (PendingRead $read): array|Throwable => $this->batchAnswers($link, $batched, [$read])[0], $reads);
        } catch (Throwable $failure) {
            return array_fill(0, \count($reads), $failure);
        }
    }

    /**
     * @param list<float|int|string|null> $params
     *
     * @return Result|list<array<array-key, string|null>>
     */
    private static function serveOne(PgLink $link, string $sql, ?BatchedRead $batched, array $params): Result|array
    {
        if ($batched === null) {
            return $link->read($sql, $params);
        }

        return self::rowsOfEach($link, $batched, [$params])[0];
    }

    /**
     * Runs one statement for the requests, and splits its rows by the request they belong to.
     *
     * @param list<list<float|int|string|null>> $paramsByRequest
     *
     * @return list<list<array<array-key, string|null>>> the rows of each request, in the order of the requests
     */
    private static function rowsOfEach(PgLink $link, BatchedRead $batched, array $paramsByRequest): array
    {
        $result = $link->read($batched->sql, BatchedRead::arrays($paramsByRequest));
        $rows = array_fill(0, \count($paramsByRequest), []);

        while (($row = pg_fetch_assoc($result)) !== false) {
            // the first column is the request's position, from 1
            $position = (int) array_shift($row);
            $rows[$position - 1][] = $row;
        }

        return $rows;
    }

    private function free(): Channel
    {
        return $this->free ??= $this->makeFree();
    }

    private function makeFree(): Channel
    {
        $free = new Channel(\count($this->links));

        foreach ($this->links as $link) {
            $free->push($link);
        }

        return $free;
    }
}
