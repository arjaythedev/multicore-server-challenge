<?php

declare(strict_types=1);

namespace App\Module\Profile\Domain\Repository;

interface FollowRepositoryInterface
{
    /**
     * Makes the follower follow the followee. Following someone already followed changes nothing.
     */
    public function add(int $followerId, int $followeeId): void;

    /**
     * Stops the follower following the followee. Unfollowing someone not followed changes nothing.
     */
    public function remove(int $followerId, int $followeeId): void;
}
