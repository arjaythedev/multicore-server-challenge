<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\UseCase;

use App\Module\Comment\Application\Mapper\CommentsResultMapper;
use App\Module\Comment\Application\Result\CommentsResult;
use App\Module\Comment\Domain\Repository\CommentRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class ListComments
{
    public function __construct(
        private readonly CommentRepositoryInterface $commentRepository,
        private readonly CommentsResultMapper $commentsResultMapper,
    ) {
    }

    public function __invoke(string $slug, int $viewerId): CommentsResult
    {
        $comments = $this->commentRepository->findNewestBySlug($slug, $viewerId)
            ?? throw NotFoundException::withMessage('article not found');

        return $this->commentsResultMapper->toResult($comments);
    }
}
