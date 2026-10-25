<?php

declare(strict_types=1);

namespace App\Module\User\Application\Query\LogIn;

use App\Module\User\Application\Port\UserReadServiceInterface;
use App\Module\User\Application\Result\SignedInUserResult;
use App\Shared\Application\Policy\NoAuthRequired;

/**
 * Checking a password writes nothing; the token it issues is signed, not stored.
 */
#[NoAuthRequired(reason: 'Logging in is how a caller gets a token.')]
final class LogInQueryHandler
{
    public function __construct(
        private readonly UserReadServiceInterface $readService,
    ) {
    }

    public function handle(LogInQuery $query): SignedInUserResult
    {
        return $this->readService->logIn($query->email, $query->password);
    }
}
