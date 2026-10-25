<?php

declare(strict_types=1);

namespace App\Module\User\Application\Mapper;

use App\Module\User\Application\Result\UserResult;
use App\Module\User\Domain\Model\User;

final class UserResultMapper
{
    public function toResult(User $user): UserResult
    {
        return new UserResult(
            email: $user->email,
            username: $user->username,
            bio: $user->bio,
            image: $user->image,
        );
    }
}
