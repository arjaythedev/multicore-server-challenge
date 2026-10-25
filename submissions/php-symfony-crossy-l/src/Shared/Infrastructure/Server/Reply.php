<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Server;

/**
 * What the server writes back for one request: the status, the headers in order, and the body.
 */
final readonly class Reply
{
    /**
     * @param list<array{string, string}> $headers name and value of each header
     */
    public function __construct(
        public int $status,
        public array $headers,
        public string $body,
    ) {
    }
}
