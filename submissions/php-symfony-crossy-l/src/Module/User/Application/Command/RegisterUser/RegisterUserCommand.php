<?php

declare(strict_types=1);

namespace App\Module\User\Application\Command\RegisterUser;

use SensitiveParameter;

final readonly class RegisterUserCommand
{
    public function __construct(
        public string $username,
        public string $email,
        #[SensitiveParameter]
        public string $password,
    ) {
    }
}
