<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Result;

use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\Model\Moment;

final readonly class ArticleResult
{
    /**
     * @param list<string> $tagList
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
        public ProfileResult $author,
    ) {
    }
}
