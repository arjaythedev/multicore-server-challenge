<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\UnfavoriteArticle;

use App\Shared\Domain\Security\CallerContext;

final readonly class UnfavoriteArticleCommand
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
    ) {
    }
}
