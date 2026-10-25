<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Application\Policy;

use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Security\CallerContext;
use PHPUnit\Framework\TestCase;

final class AuthenticatedCallerPolicyTest extends TestCase
{
    public function testRefusesAnAnonymousCaller(): void
    {
        $this->expectException(UnauthorizedException::class);

        (new AuthenticatedCallerPolicy())->authorize(CallerContext::anonymous());
    }

    public function testAcceptsAnAuthenticatedCaller(): void
    {
        (new AuthenticatedCallerPolicy())->authorize(CallerContext::authenticated(1, 'token'));

        $this->expectNotToPerformAssertions();
    }
}
