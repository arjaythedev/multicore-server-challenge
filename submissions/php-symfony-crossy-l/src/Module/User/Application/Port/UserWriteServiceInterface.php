<?php

declare(strict_types=1);

namespace App\Module\User\Application\Port;

use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Application\Result\UserResult;
use App\Module\User\Domain\Model\Exception\UsernameOrEmailTakenException;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Model\Exception\ValidationException;
use SensitiveParameter;

interface UserWriteServiceInterface
{
    /**
     * Creates an account and issues its first token.
     *
     * @throws UsernameOrEmailTakenException
     * @throws ValidationException when the password cannot be hashed whole
     */
    public function register(string $username, string $email, #[SensitiveParameter] string $password): SignedInUserResult;

    /**
     * Changes the fields that are not null and leaves the rest. A new password is hashed first.
     *
     * @throws UnauthorizedException when there is no such account
     * @throws UsernameOrEmailTakenException
     * @throws ValidationException when the password cannot be hashed whole
     */
    public function updateUser(
        int $userId,
        ?string $email,
        ?string $username,
        #[SensitiveParameter]
        ?string $password,
        ?string $bio,
        ?string $image,
    ): UserResult;
}
