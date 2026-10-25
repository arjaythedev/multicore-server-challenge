<?php

declare(strict_types=1);

namespace App\Module\User\Application\UseCase;

use App\Module\User\Application\Mapper\SignedInUserResultMapper;
use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Domain\Model\NewUser;
use App\Module\User\Domain\Repository\UserRepositoryInterface;
use App\Module\User\Domain\Security\PasswordHasherInterface;
use App\Shared\Domain\Security\AccessTokenServiceInterface;
use SensitiveParameter;

class RegisterUser
{
    public function __construct(
        private readonly UserRepositoryInterface $userRepository,
        private readonly PasswordHasherInterface $passwordHasher,
        private readonly AccessTokenServiceInterface $accessTokens,
        private readonly SignedInUserResultMapper $signedInUserResultMapper,
    ) {
    }

    public function __invoke(string $username, string $email, #[SensitiveParameter] string $password): SignedInUserResult
    {
        $user = $this->userRepository->add(new NewUser(
            username: $username,
            email: $email,
            passwordHash: $this->passwordHasher->hash($password),
        ));

        return $this->signedInUserResultMapper->toResult($user, $this->accessTokens->issue($user->id));
    }
}
