<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\UseCase;

use App\Module\Profile\Domain\Repository\ProfileRepositoryInterface;
use App\Shared\Application\Mapper\ProfileResultMapper;
use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\Model\Exception\NotFoundException;

class GetProfile
{
    public function __construct(
        private readonly ProfileRepositoryInterface $profileRepository,
        private readonly ProfileResultMapper $profileResultMapper,
    ) {
    }

    public function __invoke(string $username, int $viewerId): ProfileResult
    {
        $profile = $this->profileRepository->findByUsername($username, $viewerId)
            ?? throw NotFoundException::withMessage('profile not found');

        return $this->profileResultMapper->toResult($profile);
    }
}
