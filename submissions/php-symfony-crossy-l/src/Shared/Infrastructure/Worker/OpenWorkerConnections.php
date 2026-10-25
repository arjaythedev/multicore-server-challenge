<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Worker;

use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Shared\Infrastructure\Persistence\Pg\PgConnectionLostException;

/**
 * Opens the worker's Postgres connections when it starts. The first statement opens them if the server was not
 * reachable yet.
 */
final class OpenWorkerConnections
{
    public function __construct(
        private readonly PgConnection $connection,
    ) {
    }

    public function __invoke(): void
    {
        try {
            $this->connection->connect();
        } catch (PgConnectionLostException) {
            // an unreachable server is not an error here
        }
    }
}
