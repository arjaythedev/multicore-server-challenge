<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Exception;

use DomainException;

/**
 * The caller presented no valid credentials. Served as HTTP 401.
 */
class UnauthorizedException extends DomainException implements DomainExceptionInterface
{
    public static function withMessage(string $message): self
    {
        return new self($message);
    }
}
