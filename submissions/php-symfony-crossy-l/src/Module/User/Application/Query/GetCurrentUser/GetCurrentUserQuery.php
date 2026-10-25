<?php

declare(strict_types=1);

namespace App\Module\User\Application\Query\GetCurrentUser;

use App\Shared\Domain\Security\CallerContext;

final readonly class GetCurrentUserQuery
{
    public function __construct(
        public CallerContext $caller,
    ) {
    }
}
