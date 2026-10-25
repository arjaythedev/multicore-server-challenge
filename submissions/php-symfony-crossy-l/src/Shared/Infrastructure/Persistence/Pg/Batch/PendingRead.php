<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg\Batch;

use Swoole\Coroutine\Channel;

/**
 * A read waiting for a connection, and the channel its coroutine waits on for the answer.
 */
final readonly class PendingRead
{
    /**
     * @param list<float|int|string|null> $params
     */
    public function __construct(
        public string $sql,
        public ?BatchedRead $batched,
        public array $params,
        public Channel $reply,
    ) {
    }
}
