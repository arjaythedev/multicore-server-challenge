<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Response;

use App\Shared\Interface\Http\Response\ProfileResponse;

/**
 * An article in a list: every field of an article but the body.
 */
final readonly class ArticleSummaryResponse
{
    /**
     * @param list<string> $tagList
     */
    public function __construct(
        public string $slug,
        public string $title,
        public string $description,
        public array $tagList,
        public string $createdAt,
        public string $updatedAt,
        public bool $favorited,
        public int $favoritesCount,
        public ProfileResponse $author,
    ) {
    }
}
