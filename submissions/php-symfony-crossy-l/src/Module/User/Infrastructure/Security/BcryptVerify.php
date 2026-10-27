<?php

declare(strict_types=1);

namespace App\Module\User\Infrastructure\Security;

use App\Shared\Infrastructure\Worker\TaskJob;
use SensitiveParameter;

/**
 * @implements TaskJob<bool>
 */
final readonly class BcryptVerify implements TaskJob
{
    public function __construct(
        #[SensitiveParameter]
        private string $password,
        private string $hash,
    ) {
    }

    public function run(): bool
    {
        return password_verify($this->password, $this->hash);
    }
}
