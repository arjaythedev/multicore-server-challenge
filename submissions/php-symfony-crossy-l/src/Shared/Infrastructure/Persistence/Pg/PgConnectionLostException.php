<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg;

/**
 * The connection to Postgres could not be opened or broke. It has been discarded; the next call opens
 * a new one.
 */
final class PgConnectionLostException extends PgException
{
    private function __construct(
        string $message,
        private readonly bool $statementSent,
    ) {
        parent::__construct($message);
    }

    /**
     * @param bool $statementSent whether the statement had reached the server when the connection broke,
     *                            which decides if running it again could run it twice
     */
    public static function because(string $reason, bool $statementSent): self
    {
        return new self('postgres connection lost: ' . $reason, $statementSent);
    }

    public function wasStatementSent(): bool
    {
        return $this->statementSent;
    }
}
