<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Service;

use App\Module\Profile\Application\Port\ProfileReadServiceInterface;
use App\Module\Profile\Application\UseCase\GetProfile;
use App\Shared\Application\Result\ProfileResult;

class ProfileReadService implements ProfileReadServiceInterface
{
    public function __construct(
        private readonly GetProfile $getProfile,
    ) {
    }

    public function getProfile(string $username, int $viewerId): ProfileResult
    {
        return ($this->getProfile)($username, $viewerId);
    }
}
