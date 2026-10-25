<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\View;

use App\Shared\Domain\Model\Moment;
use App\Shared\Domain\View\ProfileView;

/**
 * One article as a viewer sees it, body included.
 */
readonly class ArticleView
{
    /**
     * @param list<string> $tagList sorted by name
     */
    public function __construct(
        public string $slug,
        public string $title,
        public string $description,
        public string $body,
        public array $tagList,
        public Moment $createdAt,
        public Moment $updatedAt,
        public bool $favorited,
        public int $favoritesCount,
        public ProfileView $author,
    ) {
    }
}
