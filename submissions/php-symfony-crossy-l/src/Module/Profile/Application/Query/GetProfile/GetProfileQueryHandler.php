<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\Query\GetProfile;

use App\Module\Profile\Application\Port\ProfileReadServiceInterface;
use App\Shared\Application\Policy\NoAuthRequired;
use App\Shared\Application\Result\ProfileResult;

#[NoAuthRequired(reason: 'Profiles are public; a signed-in viewer also learns whether they follow.')]
final class GetProfileQueryHandler
{
    public function __construct(
        private readonly ProfileReadServiceInterface $readService,
    ) {
    }

    public function handle(GetProfileQuery $query): ProfileResult
    {
        return $this->readService->getProfile($query->username, $query->caller->getViewerId());
    }
}
