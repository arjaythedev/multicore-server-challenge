<?php

declare(strict_types=1);

namespace App\Module\User\Application\Result;

/**
 * An account and a token just issued for it.
 */
final readonly class SignedInUserResult
{
    public function __construct(
        public UserResult $user,
        public string $token,
    ) {
    }
}
