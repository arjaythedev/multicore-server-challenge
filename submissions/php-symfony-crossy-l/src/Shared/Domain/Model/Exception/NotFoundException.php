<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Exception;

use DomainException;

/**
 * A record the request names does not exist. Served as HTTP 404.
 */
class NotFoundException extends DomainException implements DomainExceptionInterface
{
    public static function withMessage(string $message): self
    {
        return new self($message);
    }
}
