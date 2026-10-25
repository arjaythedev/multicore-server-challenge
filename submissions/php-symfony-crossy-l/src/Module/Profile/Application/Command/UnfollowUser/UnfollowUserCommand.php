<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Command\UnfollowUser;

use App\Shared\Domain\Security\CallerContext;

final readonly class UnfollowUserCommand
{
    public function __construct(
        public CallerContext $caller,
        public string $username,
    ) {
    }
}
