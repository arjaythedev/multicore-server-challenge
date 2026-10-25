<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\User\Infrastructure\Persistence\Pg\Mapper;

use App\Module\User\Infrastructure\Persistence\Pg\Mapper\UserCredentialsMapper;
use App\Module\User\Infrastructure\Persistence\Pg\Mapper\UserMapper;
use PHPUnit\Framework\TestCase;

final class UserMapperTest extends TestCase
{
    public function testARowBecomesAnAccount(): void
    {
        $user = (new UserMapper())->toDomain(['id' => '4', 'username' => 'jake', 'email' => 'jake@example.test', 'bio' => null, 'image' => null]);

        self::assertSame(4, $user->id);
        self::assertSame('jake', $user->username);
        self::assertSame('jake@example.test', $user->email);
        self::assertNull($user->bio);
    }

    public function testTheCredentialsAreTheAccountAndTheHash(): void
    {
        $credentials = (new UserCredentialsMapper(new UserMapper()))->toDomain([
            'id' => '4', 'username' => 'jake', 'email' => 'jake@example.test', 'bio' => 'a bio', 'image' => null, 'password_hash' => '$2y$10$hash',
        ]);

        self::assertSame('jake', $credentials->user->username);
        self::assertSame('a bio', $credentials->user->bio);
        self::assertSame('$2y$10$hash', $credentials->passwordHash);
    }
}
