<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Response;

/**
 * {"email", "token", "username", "bio", "image"}
 */
final readonly class UserResponse
{
    public function __construct(
        public string $email,
        public string $token,
        public string $username,
        public ?string $bio,
        public ?string $image,
    ) {
    }
}
