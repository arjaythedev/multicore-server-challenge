<?php

declare(strict_types=1);

namespace App\Shared\Domain\Security;

use App\Shared\Domain\Model\Exception\UnauthorizedException;

/**
 * Issues and checks the signed tokens callers present. Every check is made in full on every call.
 */
interface AccessTokenServiceInterface
{
    /**
     * The id of the user a valid token names.
     *
     * @throws UnauthorizedException when the token is malformed, signed with another key or algorithm,
     *                               expired, lacks an expiry, or names no usable user id
     */
    public function verify(string $token): int;

    public function issue(int $userId): string;
}
