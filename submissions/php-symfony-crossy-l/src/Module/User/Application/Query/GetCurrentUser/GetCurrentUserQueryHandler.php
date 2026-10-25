<?php

declare(strict_types=1);

namespace App\Module\User\Application\Query\GetCurrentUser;

use App\Module\User\Application\Port\UserReadServiceInterface;
use App\Module\User\Application\Result\UserResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class GetCurrentUserQueryHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly UserReadServiceInterface $readService,
    ) {
    }

    public function handle(GetCurrentUserQuery $query): UserResult
    {
        $this->policy->authorize($query->caller);

        return $this->readService->getCurrentUser($query->caller->getViewerId());
    }
}
