<?php

declare(strict_types=1);

namespace App\Module\Profile\Application\UseCase;

use App\Module\Profile\Domain\Repository\FollowRepositoryInterface;
use App\Module\Profile\Domain\Repository\ProfileRepositoryInterface;
use App\Shared\Application\Mapper\ProfileResultMapper;
use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\Model\Exception\NotFoundException;

class UnfollowUser
{
    public function __construct(
        private readonly ProfileRepositoryInterface $profileRepository,
        private readonly FollowRepositoryInterface $followRepository,
        private readonly ProfileResultMapper $profileResultMapper,
    ) {
    }

    /**
     * The profile comes back not followed, whether or not it was.
     */
    public function __invoke(int $followerId, string $username): ProfileResult
    {
        $followee = $this->profileRepository->findUserByUsername($username)
            ?? throw NotFoundException::withMessage('profile not found');

        $this->followRepository->remove($followerId, $followee->id);

        return $this->profileResultMapper->toResult($followee->viewedBy(viewerFollows: false));
    }
}
