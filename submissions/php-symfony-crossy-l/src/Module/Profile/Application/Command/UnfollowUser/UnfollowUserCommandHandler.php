<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Command\UnfollowUser;

use App\Module\Profile\Application\Port\ProfileWriteServiceInterface;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;
use App\Shared\Application\Result\ProfileResult;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class UnfollowUserCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly ProfileWriteServiceInterface $writeService,
    ) {
    }

    public function handle(UnfollowUserCommand $command): ProfileResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->unfollow($command->caller->getViewerId(), $command->username);
    }
}
