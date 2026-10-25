<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\CreateArticle;

use App\Shared\Domain\Security\CallerContext;

final readonly class CreateArticleCommand
{
    /**
     * @param list<string> $tagList
     */
    public function __construct(
        public CallerContext $caller,
        public string $title,
        public string $description,
        public string $body,
        public array $tagList,
    ) {
    }
}
