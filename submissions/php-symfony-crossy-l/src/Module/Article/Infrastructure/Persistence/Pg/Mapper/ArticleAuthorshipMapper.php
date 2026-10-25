<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Domain\Model\ArticleAuthorship;

final class ArticleAuthorshipMapper
{
    /**
     * @param array<array-key, string|null> $row the columns id and author_id of an article
     */
    public function toDomain(array $row): ArticleAuthorship
    {
        return new ArticleAuthorship(articleId: (int) $row['id'], authorId: (int) $row['author_id']);
    }
}
