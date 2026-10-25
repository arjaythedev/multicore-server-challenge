<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Rule\ArticleAuthorRule;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class DeleteArticle
{
    public function __construct(
        private readonly ArticleRepositoryInterface $articleRepository,
        private readonly ArticleAuthorRule $articleAuthorRule,
    ) {
    }

    public function __invoke(int $userId, string $slug): void
    {
        $authorship = $this->articleRepository->findAuthorshipBySlug($slug)
            ?? throw NotFoundException::withMessage('article not found');

        $this->articleAuthorRule->apply($authorship, $userId);

        $this->articleRepository->delete($authorship->articleId);
    }
}
