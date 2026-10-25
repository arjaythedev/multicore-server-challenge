<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Service;

use App\Module\Comment\Application\Port\CommentReadServiceInterface;
use App\Module\Comment\Application\Result\CommentsResult;
use App\Module\Comment\Application\UseCase\ListComments;

class CommentReadService implements CommentReadServiceInterface
{
    public function __construct(
        private readonly ListComments $listComments,
    ) {
    }

    public function listComments(string $slug, int $viewerId): CommentsResult
    {
        return ($this->listComments)($slug, $viewerId);
    }
}
