<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Mapper;

use App\Module\Comment\Application\Result\CommentResult;
use App\Module\Comment\Application\Result\CommentResultList;
use App\Module\Comment\Domain\View\CommentView;
use App\Module\Comment\Domain\View\CommentViewList;
use App\Shared\Application\Mapper\ProfileResultMapper;

final class CommentResultMapper
{
    public function __construct(
        private readonly ProfileResultMapper $profileResultMapper,
    ) {
    }

    public function toResult(CommentView $comment): CommentResult
    {
        return new CommentResult(
            id: $comment->id,
            createdAt: $comment->createdAt,
            updatedAt: $comment->updatedAt,
            body: $comment->body,
            author: $this->profileResultMapper->toResult($comment->author),
        );
    }

    public function toResultList(CommentViewList $comments): CommentResultList
    {
        return CommentResultList::fromArray($comments->map($this->toResult(...)));
    }
}
