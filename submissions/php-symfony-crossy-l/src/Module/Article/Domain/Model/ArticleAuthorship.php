<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Model;

/**
 * An article and who wrote it: what deciding whether a caller may edit or delete it needs.
 */
readonly class ArticleAuthorship
{
    public function __construct(
        public int $articleId,
        public int $authorId,
    ) {
    }
}
