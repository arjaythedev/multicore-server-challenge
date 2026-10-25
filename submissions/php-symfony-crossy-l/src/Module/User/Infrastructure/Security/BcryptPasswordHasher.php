<?php

declare(strict_types=1);

namespace App\Module\User\Infrastructure\Security;

use App\Module\User\Domain\Security\PasswordHasherInterface;
use App\Shared\Domain\Model\Exception\ValidationException;
use SensitiveParameter;

/**
 * It reads at most 72 bytes and refuses a NUL byte; a password it cannot take whole never matches.
 */
final class BcryptPasswordHasher implements PasswordHasherInterface
{
    private const int COST = 10;

    private const int MAX_BYTES = 72;

    public function hash(#[SensitiveParameter] string $password): string
    {
        if (!self::fitsWhole($password)) {
            throw ValidationException::withMessage('password must be at most 72 bytes and hold no NUL character');
        }

        return password_hash($password, PASSWORD_BCRYPT, ['cost' => self::COST]);
    }

    public function verify(#[SensitiveParameter] string $password, string $hash): bool
    {
        return self::fitsWhole($password) && password_verify($password, $hash);
    }

    private static function fitsWhole(string $password): bool
    {
        return \strlen($password) <= self::MAX_BYTES && !str_contains($password, "\0");
    }
}
