<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\UseCase;

use App\Module\Comment\Application\Mapper\CommentResultMapper;
use App\Module\Comment\Application\Result\CommentResult;
use App\Module\Comment\Domain\Model\NewComment;
use App\Module\Comment\Domain\Repository\CommentRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class AddComment
{
    public function __construct(
        private readonly CommentRepositoryInterface $commentRepository,
        private readonly CommentResultMapper $commentResultMapper,
    ) {
    }

    public function __invoke(int $authorId, string $slug, string $body): CommentResult
    {
        $articleId = $this->commentRepository->findArticleIdBySlug($slug)
            ?? throw NotFoundException::withMessage('article not found');

        return $this->commentResultMapper->toResult($this->commentRepository->add(new NewComment(
            articleId: $articleId,
            authorId: $authorId,
            body: $body,
        )));
    }
}
