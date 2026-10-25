<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Port;

use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\Model\Exception\NotFoundException;

interface ProfileReadServiceInterface
{
    /**
     * @throws NotFoundException when no user has the username
     */
    public function getProfile(string $username, int $viewerId): ProfileResult;
}
