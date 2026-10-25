<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Model;

/**
 * What an update writes over an account. A null field is left as it is.
 */
readonly class UserChanges
{
    public function __construct(
        public ?string $email,
        public ?string $username,
        public ?string $passwordHash,
        public ?string $bio,
        public ?string $image,
    ) {
    }
}
