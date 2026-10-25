<?php

declare(strict_types=1);

namespace App\Shared\Application\Policy;

use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Security\CallerContext;

/**
 * Refuses a caller who presented no token.
 */
final class AuthenticatedCallerPolicy implements HandlerPolicy
{
    public function authorize(CallerContext $caller): void
    {
        if ($caller->isAnonymous()) {
            throw UnauthorizedException::withMessage('authentication required');
        }
    }
}
