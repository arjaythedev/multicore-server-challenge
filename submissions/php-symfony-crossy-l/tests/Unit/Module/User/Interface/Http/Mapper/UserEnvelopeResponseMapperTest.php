<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\User\Interface\Http\Mapper;

use App\Module\User\Application\Result\UserResult;
use App\Module\User\Interface\Http\Mapper\UserEnvelopeResponseMapper;
use App\Module\User\Interface\Http\Mapper\UserResponseMapper;
use PHPUnit\Framework\TestCase;

final class UserEnvelopeResponseMapperTest extends TestCase
{
    public function testTheUserIsWrappedWithTheTokenItIsGiven(): void
    {
        $response = (new UserEnvelopeResponseMapper(new UserResponseMapper()))->toResponse(new UserResult('jake@example.test', 'jake', 'a bio', null), 'presented.token');

        self::assertSame('jake', $response->user->username);
        self::assertSame('jake@example.test', $response->user->email);
        self::assertSame('a bio', $response->user->bio);
        self::assertNull($response->user->image);
        self::assertSame('presented.token', $response->user->token);
    }
}
