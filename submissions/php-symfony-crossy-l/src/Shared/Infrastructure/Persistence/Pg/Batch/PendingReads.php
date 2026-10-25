<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg\Batch;

use App\Shared\Infrastructure\Worker\SurvivesRequests;

/**
 * The reads of a worker's requests that found every connection busy, grouped by statement. The read that has waited
 * longest is served first; when its statement can be batched, the later reads of the same statement go with it.
 */
#[SurvivesRequests(reason: 'Holds the reads waiting for a connection; a request is waiting on each of them.')]
final class PendingReads
{
    /** @var array<string, array<int, PendingRead>> the waiting reads of each statement, by the number they arrived as */
    private array $byStatement = [];

    private int $arrivals = 0;

    public function isEmpty(): bool
    {
        return $this->byStatement === [];
    }

    public function add(PendingRead $read): void
    {
        $this->byStatement[$read->sql][$this->arrivals++] = $read;
    }

    /**
     * Takes the read that has waited longest and, when it is batched, the later reads of its statement, as many as one
     * statement serves.
     *
     * @return non-empty-list<PendingRead>
     */
    public function takeOldest(): array
    {
        $sql = null;
        $oldest = \PHP_INT_MAX;

        foreach ($this->byStatement as $statement => $waiting) {
            $arrival = array_key_first($waiting);

            if ($arrival !== null && $arrival < $oldest) {
                $oldest = $arrival;
                $sql = $statement;
            }
        }

        \assert($sql !== null);

        $waiting = $this->byStatement[$sql];
        $count = $waiting[$oldest]->batched === null ? 1 : BatchedRead::MAX;
        $rest = \array_slice($waiting, $count, null, true);

        unset($this->byStatement[$sql]);

        if ($rest !== []) {
            $this->byStatement[$sql] = $rest;
        }

        $taken = array_values(\array_slice($waiting, 0, $count, true));
        \assert($taken !== []);

        return $taken;
    }
}
