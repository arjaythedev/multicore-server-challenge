<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\CreateArticle;

use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class CreateArticleCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ArticleWriteServiceInterface $writeService,
    ) {
    }

    public function handle(CreateArticleCommand $command): ArticleResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->createArticle(
            authorId: $command->caller->getViewerId(),
            title: $command->title,
            description: $command->description,
            body: $command->body,
            tagList: $command->tagList,
        );
    }
}
