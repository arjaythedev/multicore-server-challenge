<?php

declare(strict_types=1);

namespace App\Shared\Application\Mapper;

use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\View\ProfileView;

final class ProfileResultMapper
{
    public function toResult(ProfileView $profile): ProfileResult
    {
        return new ProfileResult(
            username: $profile->username,
            bio: $profile->bio,
            image: $profile->image,
            following: $profile->following,
        );
    }
}
