<?php

declare(strict_types=1);

namespace App\Module\User\Application\UseCase;

use App\Module\User\Application\Mapper\SignedInUserResultMapper;
use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Domain\Repository\UserRepositoryInterface;
use App\Module\User\Domain\Security\PasswordHasherInterface;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Security\AccessTokenServiceInterface;
use SensitiveParameter;

class LogIn
{
    public function __construct(
        private readonly UserRepositoryInterface $userRepository,
        private readonly PasswordHasherInterface $passwordHasher,
        private readonly AccessTokenServiceInterface $accessTokens,
        private readonly SignedInUserResultMapper $signedInUserResultMapper,
    ) {
    }

    /**
     * An unknown email and a wrong password are refused alike.
     */
    public function __invoke(string $email, #[SensitiveParameter] string $password): SignedInUserResult
    {
        $credentials = $this->userRepository->findCredentialsByEmail($email);

        if ($credentials === null || !$this->passwordHasher->verify($password, $credentials->passwordHash)) {
            throw UnauthorizedException::withMessage('invalid email or password');
        }

        return $this->signedInUserResultMapper->toResult($credentials->user, $this->accessTokens->issue($credentials->user->id));
    }
}
