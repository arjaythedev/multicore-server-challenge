<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\FavoriteArticle;

use App\Shared\Domain\Security\CallerContext;

final readonly class FavoriteArticleCommand
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
    ) {
    }
}
