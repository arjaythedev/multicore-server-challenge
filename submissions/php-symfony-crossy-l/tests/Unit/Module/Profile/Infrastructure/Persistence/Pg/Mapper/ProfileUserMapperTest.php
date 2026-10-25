<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Profile\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Profile\Infrastructure\Persistence\Pg\Mapper\ProfileUserMapper;
use PHPUnit\Framework\TestCase;

final class ProfileUserMapperTest extends TestCase
{
    public function testARowBecomesAUser(): void
    {
        $user = (new ProfileUserMapper())->toDomain(['id' => '4', 'username' => 'jake', 'bio' => null, 'image' => 'https://example.test/jake.png']);

        self::assertSame(4, $user->id);
        self::assertSame('jake', $user->username);
        self::assertNull($user->bio);
        self::assertSame('https://example.test/jake.png', $user->image);
    }
}
