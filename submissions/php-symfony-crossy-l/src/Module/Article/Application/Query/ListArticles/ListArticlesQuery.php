<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Query\ListArticles;

use App\Module\Article\Domain\Model\ArticleFilter;
use App\Shared\Domain\Security\CallerContext;

final readonly class ListArticlesQuery
{
    public function __construct(
        public CallerContext $caller,
        public ArticleFilter $filter,
        public int $limit,
        public int $offset,
    ) {
    }
}
