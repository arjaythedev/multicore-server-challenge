<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Command\AddComment;

use App\Module\Comment\Application\Port\CommentWriteServiceInterface;
use App\Module\Comment\Application\Result\CommentResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class AddCommentCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly CommentWriteServiceInterface $writeService,
    ) {
    }

    public function handle(AddCommentCommand $command): CommentResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->addComment($command->caller->getViewerId(), $command->slug, $command->body);
    }
}
