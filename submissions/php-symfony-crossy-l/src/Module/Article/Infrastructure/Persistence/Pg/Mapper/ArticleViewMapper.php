<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Domain\View\ArticleView;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgValue;

final class ArticleViewMapper
{
    public function __construct(
        private readonly ProfileViewMapper $profileViewMapper,
    ) {
    }

    /**
     * @param array<array-key, string|null> $row
     */
    public function toView(array $row): ArticleView
    {
        return new ArticleView(
            slug: (string) $row['slug'],
            title: (string) $row['title'],
            description: (string) $row['description'],
            body: (string) $row['body'],
            tagList: PgValue::textArray($row['tag_list']),
            createdAt: PgValue::moment($row['created_at']),
            updatedAt: PgValue::moment($row['updated_at']),
            favorited: PgValue::bool($row['favorited']),
            favoritesCount: (int) $row['favorites_count'],
            author: $this->profileViewMapper->toView($row),
        );
    }
}
