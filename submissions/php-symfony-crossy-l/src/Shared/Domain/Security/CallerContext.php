<?php

declare(strict_types=1);

namespace App\Shared\Domain\Security;

use App\Shared\Domain\Model\Exception\UnauthorizedException;

/**
 * Who is making a request: the user the token names and the token as presented, or nobody.
 */
final readonly class CallerContext
{
    /** The viewer id of a caller who presented no token. No user has this id. */
    public const int ANONYMOUS_VIEWER_ID = 0;

    private function __construct(
        private int $viewerId,
        private ?string $token,
    ) {
    }

    public static function anonymous(): self
    {
        return new self(self::ANONYMOUS_VIEWER_ID, null);
    }

    public static function authenticated(int $viewerId, string $token): self
    {
        return new self($viewerId, $token);
    }

    public function isAnonymous(): bool
    {
        return $this->token === null;
    }

    public function getViewerId(): int
    {
        return $this->viewerId;
    }

    /**
     * The token the request presented, echoed back by the endpoints that return the caller's user.
     */
    public function getToken(): ?string
    {
        return $this->token;
    }

    /**
     * The token of a caller who presented one. An anonymous caller is refused as unauthenticated.
     *
     * @throws UnauthorizedException
     */
    public function getPresentedToken(): string
    {
        return $this->token ?? throw UnauthorizedException::withMessage('authentication required');
    }
}
