<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Security;

use App\Shared\Domain\Model\Exception\ValidationException;
use SensitiveParameter;

/**
 * Hashes passwords and checks them against a stored hash. Every call does the full work.
 */
interface PasswordHasherInterface
{
    /**
     * @throws ValidationException when the hash cannot take the password whole
     */
    public function hash(#[SensitiveParameter] string $password): string;

    /**
     * Whether the password is the one the hash was made from. A password the hash could never have
     * taken whole does not match.
     */
    public function verify(#[SensitiveParameter] string $password, string $hash): bool;
}
