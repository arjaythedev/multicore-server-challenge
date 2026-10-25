<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Port;

use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\Model\Exception\NotFoundException;

interface ProfileWriteServiceInterface
{
    /**
     * @throws NotFoundException when no user has the username
     */
    public function follow(int $followerId, string $username): ProfileResult;

    /**
     * @throws NotFoundException when no user has the username
     */
    public function unfollow(int $followerId, string $username): ProfileResult;
}
