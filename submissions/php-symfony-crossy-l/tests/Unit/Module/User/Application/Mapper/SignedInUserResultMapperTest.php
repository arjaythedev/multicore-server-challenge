<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\User\Application\Mapper;

use App\Module\User\Application\Mapper\SignedInUserResultMapper;
use App\Module\User\Application\Mapper\UserResultMapper;
use App\Module\User\Domain\Model\User;
use PHPUnit\Framework\TestCase;

final class SignedInUserResultMapperTest extends TestCase
{
    public function testTheUserIsMappedByItsOwnMapperAndTheTokenIsKept(): void
    {
        $result = (new SignedInUserResultMapper(new UserResultMapper()))->toResult(new User(4, 'jake', 'jake@example.test', null, 'https://example.test/jake.png'), 'a.token.value');

        self::assertSame('jake', $result->user->username);
        self::assertSame('jake@example.test', $result->user->email);
        self::assertNull($result->user->bio);
        self::assertSame('https://example.test/jake.png', $result->user->image);
        self::assertSame('a.token.value', $result->token);
    }
}
