<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg;

/**
 * Postgres refused a statement on a connection that is still good. The SQLSTATE says why.
 */
final class PgQueryFailedException extends PgException
{
    /** SQLSTATE of a unique constraint violation. */
    public const string UNIQUE_VIOLATION = '23505';

    private function __construct(
        string $message,
        private readonly string $sqlState,
    ) {
        parent::__construct($message);
    }

    public static function withSqlState(string $sqlState, string $message): self
    {
        return new self(\sprintf('postgres error %s: %s', $sqlState, $message), $sqlState);
    }

    public function getSqlState(): string
    {
        return $this->sqlState;
    }

    public function isUniqueViolation(): bool
    {
        return $this->sqlState === self::UNIQUE_VIOLATION;
    }
}
