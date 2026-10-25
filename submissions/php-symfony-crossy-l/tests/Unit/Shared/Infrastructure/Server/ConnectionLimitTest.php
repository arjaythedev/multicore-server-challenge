<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Server;

use App\Shared\Infrastructure\Server\ConnectionLimit;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class ConnectionLimitTest extends TestCase
{
    #[DataProvider('limits')]
    public function testItLeavesRoomForTheDescriptorsThatAreNotConnections(int|string $openFiles, int $expected): void
    {
        self::assertSame($expected, ConnectionLimit::forOpenFiles($openFiles));
    }

    /**
     * @return iterable<string, array{int|string, int}>
     */
    public static function limits(): iterable
    {
        yield 'the box sets 200000, which is more than is wanted' => [200000, 199000];
        yield 'a million is capped at what the server is set up for' => [1048576, 200000];
        yield 'no limit is the most' => ['unlimited', 200000];
        yield 'a small limit keeps its room' => [8192, 7192];
        yield 'the usual default of 1024 is not made smaller' => [1024, 1024];
        yield 'a limit below the reserve is not made smaller either' => [500, 1024];
    }
}
