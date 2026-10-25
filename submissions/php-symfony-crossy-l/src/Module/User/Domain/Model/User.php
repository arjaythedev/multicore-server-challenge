<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Model;

/**
 * An account as its owner sees it.
 */
readonly class User
{
    public function __construct(
        public int $id,
        public string $username,
        public string $email,
        public ?string $bio,
        public ?string $image,
    ) {
    }
}
