<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Model;

/**
 * An account about to be created. It starts with no bio and no image.
 */
readonly class NewUser
{
    public function __construct(
        public string $username,
        public string $email,
        public string $passwordHash,
    ) {
    }
}
