<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Domain\Security;

use App\Shared\Domain\Security\CallerContext;
use PHPUnit\Framework\TestCase;

final class CallerContextTest extends TestCase
{
    public function testAnAnonymousCallerIsViewerZeroWithNoToken(): void
    {
        $caller = CallerContext::anonymous();

        self::assertTrue($caller->isAnonymous());
        self::assertSame(0, $caller->getViewerId());
        self::assertNull($caller->getToken());
    }

    public function testAnAuthenticatedCallerCarriesItsIdAndTheTokenItPresented(): void
    {
        $caller = CallerContext::authenticated(42, 'a.b.c');

        self::assertFalse($caller->isAnonymous());
        self::assertSame(42, $caller->getViewerId());
        self::assertSame('a.b.c', $caller->getToken());
    }
}
