<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Mapper;

use App\Module\User\Application\Result\UserResult;
use App\Module\User\Interface\Http\Response\UserEnvelopeResponse;

final class UserEnvelopeResponseMapper
{
    public function __construct(
        private readonly UserResponseMapper $userResponseMapper,
    ) {
    }

    /**
     * @param string $token a token just issued, or the one the request presented
     */
    public function toResponse(UserResult $user, string $token): UserEnvelopeResponse
    {
        return new UserEnvelopeResponse(user: $this->userResponseMapper->toResponse($user, $token));
    }
}
