<?php

declare(strict_types=1);

namespace App\Module\User\Application\UseCase;

use App\Module\User\Application\Mapper\UserResultMapper;
use App\Module\User\Application\Result\UserResult;
use App\Module\User\Domain\Repository\UserRepositoryInterface;
use App\Shared\Domain\Model\Exception\UnauthorizedException;

class GetCurrentUser
{
    public function __construct(
        private readonly UserRepositoryInterface $userRepository,
        private readonly UserResultMapper $userResultMapper,
    ) {
    }

    public function __invoke(int $userId): UserResult
    {
        $user = $this->userRepository->findById($userId)
            ?? throw UnauthorizedException::withMessage('the token names no account');

        return $this->userResultMapper->toResult($user);
    }
}
