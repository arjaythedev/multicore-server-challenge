<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Response;

/**
 * {"user": User}
 */
final readonly class UserEnvelopeResponse
{
    public function __construct(
        public UserResponse $user,
    ) {
    }
}
