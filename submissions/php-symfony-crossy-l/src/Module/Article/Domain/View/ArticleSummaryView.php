<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\View;

use App\Shared\Domain\Model\Moment;
use App\Shared\Domain\View\ProfileView;

/**
 * An article in a list, as a viewer sees it: everything but the body.
 */
readonly class ArticleSummaryView
{
    /**
     * @param list<string> $tagList sorted by name
     */
    public function __construct(
        public string $slug,
        public string $title,
        public string $description,
        public array $tagList,
        public Moment $createdAt,
        public Moment $updatedAt,
        public bool $favorited,
        public int $favoritesCount,
        public ProfileView $author,
    ) {
    }
}
