<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Rule;

use App\Module\Article\Domain\Model\ArticleAuthorship;
use App\Shared\Domain\Model\Exception\ForbiddenException;

/**
 * Only an article's author may edit or delete it. Anyone may learn that the article exists.
 */
final class ArticleAuthorRule
{
    public function apply(ArticleAuthorship $article, int $userId): void
    {
        if ($article->authorId !== $userId) {
            throw ForbiddenException::withMessage('only the author may change this article');
        }
    }
}
