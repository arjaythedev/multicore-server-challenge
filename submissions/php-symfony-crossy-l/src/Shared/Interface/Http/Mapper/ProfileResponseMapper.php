<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http\Mapper;

use App\Shared\Application\Result\ProfileResult;
use App\Shared\Interface\Http\Response\ProfileResponse;

final class ProfileResponseMapper
{
    public function toResponse(ProfileResult $profile): ProfileResponse
    {
        return new ProfileResponse(
            username: $profile->username,
            bio: $profile->bio,
            image: $profile->image,
            following: $profile->following,
        );
    }
}
