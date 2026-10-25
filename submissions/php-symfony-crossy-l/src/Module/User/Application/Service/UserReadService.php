<?php

declare(strict_types=1);

namespace App\Module\User\Application\Service;

use App\Module\User\Application\Port\UserReadServiceInterface;
use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Application\Result\UserResult;
use App\Module\User\Application\UseCase\GetCurrentUser;
use App\Module\User\Application\UseCase\LogIn;
use SensitiveParameter;

class UserReadService implements UserReadServiceInterface
{
    public function __construct(
        private readonly GetCurrentUser $getCurrentUser,
        private readonly LogIn $logIn,
    ) {
    }

    public function getCurrentUser(int $userId): UserResult
    {
        return ($this->getCurrentUser)($userId);
    }

    public function logIn(string $email, #[SensitiveParameter] string $password): SignedInUserResult
    {
        return ($this->logIn)($email, $password);
    }
}
