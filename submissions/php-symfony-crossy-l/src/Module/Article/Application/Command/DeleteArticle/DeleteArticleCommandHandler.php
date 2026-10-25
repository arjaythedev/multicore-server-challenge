<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\DeleteArticle;

use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

/**
 * Whether the caller wrote the article is decided where the article is read.
 */
#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class DeleteArticleCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ArticleWriteServiceInterface $writeService,
    ) {
    }

    public function handle(DeleteArticleCommand $command): void
    {
        $this->policy->authorize($command->caller);

        $this->writeService->deleteArticle($command->caller->getViewerId(), $command->slug);
    }
}
