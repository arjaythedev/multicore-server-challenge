<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Query\ListComments;

use App\Shared\Domain\Security\CallerContext;

final readonly class ListCommentsQuery
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
    ) {
    }
}
