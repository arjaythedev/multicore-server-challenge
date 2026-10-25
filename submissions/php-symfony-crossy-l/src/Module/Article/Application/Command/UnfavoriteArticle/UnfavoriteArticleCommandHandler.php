<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\UnfavoriteArticle;

use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class UnfavoriteArticleCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ArticleWriteServiceInterface $writeService,
    ) {
    }

    public function handle(UnfavoriteArticleCommand $command): ArticleResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->unfavoriteArticle($command->caller->getViewerId(), $command->slug);
    }
}
