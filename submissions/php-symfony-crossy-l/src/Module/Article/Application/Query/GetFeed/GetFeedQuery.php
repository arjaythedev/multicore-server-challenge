<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Query\GetFeed;

use App\Shared\Domain\Security\CallerContext;

final readonly class GetFeedQuery
{
    public function __construct(
        public CallerContext $caller,
        public int $limit,
        public int $offset,
    ) {
    }
}
