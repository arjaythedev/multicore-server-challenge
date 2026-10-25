<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Service;

use App\Module\Comment\Application\Port\CommentWriteServiceInterface;
use App\Module\Comment\Application\Result\CommentResult;
use App\Module\Comment\Application\UseCase\AddComment;
use App\Module\Comment\Application\UseCase\DeleteComment;

class CommentWriteService implements CommentWriteServiceInterface
{
    public function __construct(
        private readonly AddComment $addComment,
        private readonly DeleteComment $deleteComment,
    ) {
    }

    public function addComment(int $authorId, string $slug, string $body): CommentResult
    {
        return ($this->addComment)($authorId, $slug, $body);
    }

    public function deleteComment(int $userId, string $slug, int $commentId): void
    {
        ($this->deleteComment)($userId, $slug, $commentId);
    }
}
