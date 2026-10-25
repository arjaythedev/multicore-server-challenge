<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Model\Exception;

use App\Shared\Domain\Model\Exception\ValidationException;

/**
 * Another account already has the username or the email. Served as HTTP 422.
 */
final class UsernameOrEmailTakenException extends ValidationException
{
    private const string MESSAGE = 'username or email is already taken';

    public static function create(): self
    {
        return new self(self::MESSAGE, [self::MESSAGE]);
    }
}
