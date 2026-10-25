<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Service;

use App\Module\Profile\Application\Port\ProfileWriteServiceInterface;
use App\Module\Profile\Application\UseCase\FollowUser;
use App\Module\Profile\Application\UseCase\UnfollowUser;
use App\Shared\Application\Result\ProfileResult;

class ProfileWriteService implements ProfileWriteServiceInterface
{
    public function __construct(
        private readonly FollowUser $followUser,
        private readonly UnfollowUser $unfollowUser,
    ) {
    }

    public function follow(int $followerId, string $username): ProfileResult
    {
        return ($this->followUser)($followerId, $username);
    }

    public function unfollow(int $followerId, string $username): ProfileResult
    {
        return ($this->unfollowUser)($followerId, $username);
    }
}
