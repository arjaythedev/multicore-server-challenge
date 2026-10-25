<?php

declare(strict_types=1);

namespace App\Module\User\Application\Command\RegisterUser;

use App\Module\User\Application\Port\UserWriteServiceInterface;
use App\Module\User\Application\Result\SignedInUserResult;
use App\Shared\Application\Policy\NoAuthRequired;

#[NoAuthRequired(reason: 'Registering is how a caller gets an account and a first token.')]
final class RegisterUserCommandHandler
{
    public function __construct(
        private readonly UserWriteServiceInterface $writeService,
    ) {
    }

    public function handle(RegisterUserCommand $command): SignedInUserResult
    {
        return $this->writeService->register($command->username, $command->email, $command->password);
    }
}
