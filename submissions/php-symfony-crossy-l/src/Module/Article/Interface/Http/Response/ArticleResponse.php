<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Response;

use App\Shared\Interface\Http\Response\ProfileResponse;

/**
 * {"slug", "title", "description", "body", "tagList", "createdAt", "updatedAt", "favorited",
 * "favoritesCount", "author": Profile}
 */
final readonly class ArticleResponse
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
        public string $createdAt,
        public string $updatedAt,
        public bool $favorited,
        public int $favoritesCount,
        public ProfileResponse $author,
    ) {
    }
}
