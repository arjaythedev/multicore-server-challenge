<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Mapper;

use App\Module\User\Application\Result\UserResult;
use App\Module\User\Interface\Http\Response\UserResponse;

final class UserResponseMapper
{
    /**
     * @param string $token a token just issued, or the one the request presented
     */
    public function toResponse(UserResult $user, string $token): UserResponse
    {
        return new UserResponse(
            email: $user->email,
            token: $token,
            username: $user->username,
            bio: $user->bio,
            image: $user->image,
        );
    }
}
