<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Port;

use App\Module\Comment\Application\Result\CommentsResult;
use App\Shared\Domain\Model\Exception\NotFoundException;

interface CommentReadServiceInterface
{
    /**
     * The article's newest 100 comments, newest first. Viewer 0, the anonymous one, follows nobody.
     *
     * @throws NotFoundException when there is no article with the slug
     */
    public function listComments(string $slug, int $viewerId): CommentsResult;
}
