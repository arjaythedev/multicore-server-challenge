<?php

declare(strict_types=1);

namespace App\Module\User\Application\Query\LogIn;

use SensitiveParameter;

final readonly class LogInQuery
{
    public function __construct(
        public string $email,
        #[SensitiveParameter]
        public string $password,
    ) {
    }
}
