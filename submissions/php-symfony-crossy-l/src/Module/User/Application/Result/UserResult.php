<?php

declare(strict_types=1);

namespace App\Module\User\Application\Result;

final readonly class UserResult
{
    public function __construct(
        public string $email,
        public string $username,
        public ?string $bio,
        public ?string $image,
    ) {
    }
}
