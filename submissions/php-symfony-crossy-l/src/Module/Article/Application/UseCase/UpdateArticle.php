<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticleResultMapper;
use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Application\Rule\ArticleAuthorRule;
use App\Module\Article\Domain\Model\ArticleChanges;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class UpdateArticle
{
    public function __construct(
        private readonly ArticleRepositoryInterface $articleRepository,
        private readonly ArticleAuthorRule $articleAuthorRule,
        private readonly ArticleResultMapper $articleResultMapper,
    ) {
    }

    public function __invoke(int $userId, string $slug, ?string $title, ?string $description, ?string $body): ArticleResult
    {
        $authorship = $this->articleRepository->findAuthorshipBySlug($slug)
            ?? throw NotFoundException::withMessage('article not found');

        $this->articleAuthorRule->apply($authorship, $userId);

        $this->articleRepository->update($authorship->articleId, new ArticleChanges(
            title: $title,
            description: $description,
            body: $body,
        ));

        $article = $this->articleRepository->findById($authorship->articleId, $userId)
            ?? throw NotFoundException::withMessage('article not found');

        return $this->articleResultMapper->toResult($article);
    }
}
