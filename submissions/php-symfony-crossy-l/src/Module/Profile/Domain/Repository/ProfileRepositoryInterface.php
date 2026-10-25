<?php

declare(strict_types=1);

namespace App\Module\Profile\Domain\Repository;

use App\Module\Profile\Domain\Model\ProfileUser;
use App\Shared\Domain\View\ProfileView;

interface ProfileRepositoryInterface
{
    /**
     * The profile as the viewer sees it. Viewer 0, the anonymous one, follows nobody.
     */
    public function findByUsername(string $username, int $viewerId): ?ProfileView;

    public function findUserByUsername(string $username): ?ProfileUser;
}
