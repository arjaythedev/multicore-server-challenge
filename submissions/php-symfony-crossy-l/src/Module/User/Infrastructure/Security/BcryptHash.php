<?php

declare(strict_types=1);

namespace App\Module\User\Infrastructure\Security;

use App\Shared\Infrastructure\Worker\TaskJob;
use SensitiveParameter;

/**
 * @implements TaskJob<string>
 */
final readonly class BcryptHash implements TaskJob
{
    public function __construct(
        #[SensitiveParameter]
        private string $password,
        private int $cost,
    ) {
    }

    public function run(): string
    {
        return password_hash($this->password, PASSWORD_BCRYPT, ['cost' => $this->cost]);
    }
}
