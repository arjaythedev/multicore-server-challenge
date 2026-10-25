<?php

declare(strict_types=1);

namespace App\Module\User\Application\Service;

use App\Module\User\Application\Port\UserWriteServiceInterface;
use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Application\Result\UserResult;
use App\Module\User\Application\UseCase\RegisterUser;
use App\Module\User\Application\UseCase\UpdateUser;
use SensitiveParameter;

class UserWriteService implements UserWriteServiceInterface
{
    public function __construct(
        private readonly RegisterUser $registerUser,
        private readonly UpdateUser $updateUser,
    ) {
    }

    public function register(string $username, string $email, #[SensitiveParameter] string $password): SignedInUserResult
    {
        return ($this->registerUser)($username, $email, $password);
    }

    public function updateUser(
        int $userId,
        ?string $email,
        ?string $username,
        #[SensitiveParameter]
        ?string $password,
        ?string $bio,
        ?string $image,
    ): UserResult {
        return ($this->updateUser)($userId, $email, $username, $password, $bio, $image);
    }
}
