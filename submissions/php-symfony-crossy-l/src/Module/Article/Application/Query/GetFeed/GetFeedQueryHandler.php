<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Query\GetFeed;

use App\Module\Article\Application\Port\ArticleReadServiceInterface;
use App\Module\Article\Application\Result\ArticlesResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class GetFeedQueryHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ArticleReadServiceInterface $readService,
    ) {
    }

    public function handle(GetFeedQuery $query): ArticlesResult
    {
        $this->policy->authorize($query->caller);

        return $this->readService->getFeed($query->caller->getViewerId(), $query->limit, $query->offset);
    }
}
