<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Exception;

use DomainException;

/**
 * The caller may not act on the record. Served as HTTP 403.
 */
class ForbiddenException extends DomainException implements DomainExceptionInterface
{
    public static function withMessage(string $message): self
    {
        return new self($message);
    }
}
