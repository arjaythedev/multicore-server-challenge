<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Port;

use App\Module\Comment\Application\Result\CommentResult;
use App\Shared\Domain\Model\Exception\ForbiddenException;
use App\Shared\Domain\Model\Exception\NotFoundException;

interface CommentWriteServiceInterface
{
    /**
     * @throws NotFoundException when there is no article with the slug
     */
    public function addComment(int $authorId, string $slug, string $body): CommentResult;

    /**
     * @throws NotFoundException when the article has no comment with the id
     * @throws ForbiddenException when the user is not the comment's author
     */
    public function deleteComment(int $userId, string $slug, int $commentId): void;
}
