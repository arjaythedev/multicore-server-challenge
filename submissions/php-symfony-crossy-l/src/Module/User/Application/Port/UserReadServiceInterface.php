<?php

declare(strict_types=1);

namespace App\Module\User\Application\Port;

use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Application\Result\UserResult;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use SensitiveParameter;

interface UserReadServiceInterface
{
    /**
     * The account a signed-in caller's token names.
     *
     * @throws UnauthorizedException when there is no such account
     */
    public function getCurrentUser(int $userId): UserResult;

    /**
     * The account with this email and password, with a new token.
     *
     * @throws UnauthorizedException when no account has the email or the password does not match
     */
    public function logIn(string $email, #[SensitiveParameter] string $password): SignedInUserResult;
}
