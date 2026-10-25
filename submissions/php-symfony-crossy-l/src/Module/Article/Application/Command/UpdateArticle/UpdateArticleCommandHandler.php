<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\UpdateArticle;

use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

/**
 * Whether the caller wrote the article is decided where the article is read.
 */
#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class UpdateArticleCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ArticleWriteServiceInterface $writeService,
    ) {
    }

    public function handle(UpdateArticleCommand $command): ArticleResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->updateArticle(
            userId: $command->caller->getViewerId(),
            slug: $command->slug,
            title: $command->title,
            description: $command->description,
            body: $command->body,
        );
    }
}
