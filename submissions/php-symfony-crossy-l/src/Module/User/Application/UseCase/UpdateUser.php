<?php

declare(strict_types=1);

namespace App\Module\User\Application\UseCase;

use App\Module\User\Application\Mapper\UserResultMapper;
use App\Module\User\Application\Result\UserResult;
use App\Module\User\Domain\Model\UserChanges;
use App\Module\User\Domain\Repository\UserRepositoryInterface;
use App\Module\User\Domain\Security\PasswordHasherInterface;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use SensitiveParameter;

class UpdateUser
{
    public function __construct(
        private readonly UserRepositoryInterface $userRepository,
        private readonly PasswordHasherInterface $passwordHasher,
        private readonly UserResultMapper $userResultMapper,
    ) {
    }

    public function __invoke(
        int $userId,
        ?string $email,
        ?string $username,
        #[SensitiveParameter]
        ?string $password,
        ?string $bio,
        ?string $image,
    ): UserResult {
        $user = $this->userRepository->update($userId, new UserChanges(
            email: $email,
            username: $username,
            passwordHash: $password === null ? null : $this->passwordHasher->hash($password),
            bio: $bio,
            image: $image,
        )) ?? throw UnauthorizedException::withMessage('the token names no account');

        return $this->userResultMapper->toResult($user);
    }
}
