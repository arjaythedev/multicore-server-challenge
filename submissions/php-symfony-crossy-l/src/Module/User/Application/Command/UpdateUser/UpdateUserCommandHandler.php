<?php

declare(strict_types=1);

namespace App\Module\User\Application\Command\UpdateUser;

use App\Module\User\Application\Port\UserWriteServiceInterface;
use App\Module\User\Application\Result\UserResult;
use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Application\Policy\AuthorizationPolicy;

#[AuthorizationPolicy(policyClass: AuthenticatedCallerPolicy::class)]
final class UpdateUserCommandHandler
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
        private readonly UserWriteServiceInterface $writeService,
    ) {
    }

    public function handle(UpdateUserCommand $command): UserResult
    {
        $this->policy->authorize($command->caller);

        return $this->writeService->updateUser(
            userId: $command->caller->getViewerId(),
            email: $command->email,
            username: $command->username,
            password: $command->password,
            bio: $command->bio,
            image: $command->image,
        );
    }
}
