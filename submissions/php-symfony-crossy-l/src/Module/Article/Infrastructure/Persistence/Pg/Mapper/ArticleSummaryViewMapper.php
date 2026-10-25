<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Domain\View\ArticleSummaryView;
use App\Module\Article\Domain\View\ArticleSummaryViewList;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgValue;

final class ArticleSummaryViewMapper
{
    public function __construct(
        private readonly ProfileViewMapper $profileViewMapper,
    ) {
    }

    /**
     * @param array<array-key, string|null> $row
     */
    public function toView(array $row): ArticleSummaryView
    {
        return new ArticleSummaryView(
            slug: (string) $row['slug'],
            title: (string) $row['title'],
            description: (string) $row['description'],
            tagList: PgValue::textArray($row['tag_list']),
            createdAt: PgValue::moment($row['created_at']),
            updatedAt: PgValue::moment($row['updated_at']),
            favorited: PgValue::bool($row['favorited']),
            favoritesCount: (int) $row['favorites_count'],
            author: $this->profileViewMapper->toView($row),
        );
    }

    /**
     * A page with no articles is one row whose article columns are all NULL, which is no article.
     *
     * @param list<array<array-key, string|null>> $rows
     */
    public function toViewList(array $rows): ArticleSummaryViewList
    {
        $articles = [];

        foreach ($rows as $row) {
            if ($row['id'] !== null) {
                $articles[] = $this->toView($row);
            }
        }

        return ArticleSummaryViewList::fromArray($articles);
    }
}
