<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\FavoriteArticle;

use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class FavoriteArticleCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ArticleWriteServiceInterface $writeService,
    ) {
    }

    public function handle(FavoriteArticleCommand $command): ArticleResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->favoriteArticle($command->caller->getViewerId(), $command->slug);
    }
}
