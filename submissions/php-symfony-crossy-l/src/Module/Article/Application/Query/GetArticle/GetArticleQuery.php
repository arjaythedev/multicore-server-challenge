<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Query\GetArticle;

use App\Shared\Domain\Security\CallerContext;

final readonly class GetArticleQuery
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
    ) {
    }
}
