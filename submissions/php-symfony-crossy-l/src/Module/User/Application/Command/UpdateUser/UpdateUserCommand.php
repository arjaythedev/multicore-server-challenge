<?php

declare(strict_types=1);

namespace App\Module\User\Application\Command\UpdateUser;

use App\Shared\Domain\Security\CallerContext;
use SensitiveParameter;

/**
 * A null field is left unchanged.
 */
final readonly class UpdateUserCommand
{
    public function __construct(
        public CallerContext $caller,
        public ?string $email,
        public ?string $username,
        #[SensitiveParameter]
        public ?string $password,
        public ?string $bio,
        public ?string $image,
    ) {
    }
}
