<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Model;

/**
 * An account and the hash its password is checked against.
 */
readonly class UserCredentials
{
    public function __construct(
        public User $user,
        public string $passwordHash,
    ) {
    }
}
