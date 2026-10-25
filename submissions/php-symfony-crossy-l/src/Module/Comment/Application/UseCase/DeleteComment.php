<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\UseCase;

use App\Module\Comment\Application\Rule\CommentAuthorRule;
use App\Module\Comment\Domain\Repository\CommentRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class DeleteComment
{
    public function __construct(
        private readonly CommentRepositoryInterface $commentRepository,
        private readonly CommentAuthorRule $commentAuthorRule,
    ) {
    }

    public function __invoke(int $userId, string $slug, int $commentId): void
    {
        $authorship = $this->commentRepository->findAuthorshipOnArticle($commentId, $slug)
            ?? throw NotFoundException::withMessage('comment not found');

        $this->commentAuthorRule->apply($authorship, $userId);

        $this->commentRepository->delete($authorship->commentId);
    }
}
