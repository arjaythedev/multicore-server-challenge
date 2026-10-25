<?php

declare(strict_types=1);

namespace App\Module\User\Application\Mapper;

use App\Module\User\Application\Result\SignedInUserResult;
use App\Module\User\Domain\Model\User;

final class SignedInUserResultMapper
{
    public function __construct(
        private readonly UserResultMapper $userResultMapper,
    ) {
    }

    /**
     * @param string $token the token just issued for the user
     */
    public function toResult(User $user, string $token): SignedInUserResult
    {
        return new SignedInUserResult(user: $this->userResultMapper->toResult($user), token: $token);
    }
}
