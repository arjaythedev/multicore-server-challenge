<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Persistence\Pg\Mapper;

use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use PHPUnit\Framework\TestCase;

final class ProfileViewMapperTest extends TestCase
{
    public function testTheAuthorColumnsOfARowBecomeAProfile(): void
    {
        $profile = (new ProfileViewMapper())->toView(['username' => 'jake', 'bio' => 'a bio', 'image' => null, 'following' => 't', 'id' => '4']);

        self::assertSame('jake', $profile->username);
        self::assertSame('a bio', $profile->bio);
        self::assertNull($profile->image);
        self::assertTrue($profile->following);
    }

    public function testPostgresWritesFalseAsF(): void
    {
        self::assertFalse((new ProfileViewMapper())->toView(['username' => 'anna', 'bio' => null, 'image' => null, 'following' => 'f'])->following);
    }
}
