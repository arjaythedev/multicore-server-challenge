<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Command\DeleteComment;

use App\Module\Comment\Application\Port\CommentWriteServiceInterface;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

/**
 * Whether the caller wrote the comment is decided where the comment is read.
 */
#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class DeleteCommentCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly CommentWriteServiceInterface $writeService,
    ) {
    }

    public function handle(DeleteCommentCommand $command): void
    {
        $this->policy->authorize($command->caller);

        $this->writeService->deleteComment($command->caller->getViewerId(), $command->slug, $command->commentId);
    }
}
