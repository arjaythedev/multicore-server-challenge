<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http;

use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Security\AccessTokenServiceInterface;
use App\Shared\Domain\Security\CallerContext;
use Symfony\Component\HttpFoundation\Request;

/**
 * Builds the CallerContext a controller asks for from the request's Authorization header.
 * No header means an anonymous caller; a header that is present must carry a valid `Token <jwt>`, else 401, even
 * where signing in is optional.
 */
final class CallerContextFactory
{
    private const string SCHEME = 'Token ';

    public function __construct(
        private readonly AccessTokenServiceInterface $tokens,
    ) {
    }

    /**
     * @throws UnauthorizedException
     */
    public function fromRequest(Request $request): CallerContext
    {
        $header = $request->headers->get('Authorization');

        if ($header === null || $header === '') {
            return CallerContext::anonymous();
        }

        if (!str_starts_with($header, self::SCHEME)) {
            throw UnauthorizedException::withMessage('authorization must be "Token <jwt>"');
        }

        $token = substr($header, \strlen(self::SCHEME));

        return CallerContext::authenticated($this->tokens->verify($token), $token);
    }
}
