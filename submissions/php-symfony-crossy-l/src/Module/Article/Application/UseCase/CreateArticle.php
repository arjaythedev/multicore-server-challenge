<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticleResultMapper;
use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Domain\Model\NewArticle;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class CreateArticle
{
    public function __construct(
        private readonly ArticleRepositoryInterface $articleRepository,
        private readonly ArticleResultMapper $articleResultMapper,
    ) {
    }

    /**
     * The article is read back once it is committed, as its author sees it.
     *
     * @param list<string> $tagList
     */
    public function __invoke(int $authorId, string $title, string $description, string $body, array $tagList): ArticleResult
    {
        $id = $this->articleRepository->add(new NewArticle(
            authorId: $authorId,
            title: $title,
            description: $description,
            body: $body,
            tagList: $tagList,
        ));

        $article = $this->articleRepository->findById($id, $authorId)
            ?? throw NotFoundException::withMessage('article not found');

        return $this->articleResultMapper->toResult($article);
    }
}
