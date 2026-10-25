<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Query\ListComments;

use App\Module\Comment\Application\Port\CommentReadServiceInterface;
use App\Module\Comment\Application\Result\CommentsResult;
use App\Shared\Application\Policy\NoAuthRequired;

#[NoAuthRequired(reason: 'Comments are public; a signed-in viewer also sees which authors they follow.')]
final class ListCommentsQueryHandler
{
    public function __construct(
        private readonly CommentReadServiceInterface $readService,
    ) {
    }

    public function handle(ListCommentsQuery $query): CommentsResult
    {
        return $this->readService->listComments($query->slug, $query->caller->getViewerId());
    }
}
