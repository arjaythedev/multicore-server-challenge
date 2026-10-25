<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Mapper;

use App\Module\Comment\Application\Result\CommentsResult;
use App\Module\Comment\Domain\View\CommentViewList;

final class CommentsResultMapper
{
    public function __construct(
        private readonly CommentResultMapper $commentResultMapper,
    ) {
    }

    public function toResult(CommentViewList $comments): CommentsResult
    {
        return new CommentsResult(comments: $this->commentResultMapper->toResultList($comments));
    }
}
