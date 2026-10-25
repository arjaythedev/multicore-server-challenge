<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Interface\Http;

use App\Shared\Interface\Http\JsonResponder;
use PHPUnit\Framework\TestCase;

final class JsonResponderTest extends TestCase
{
    public function testSendsTheObjectAsJsonWithTheGivenStatus(): void
    {
        $response = (new JsonResponder())->respond((object) ['name' => 'héllo/wörld', 'count' => 2], 201);

        self::assertSame(201, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));
        self::assertSame('{"name":"héllo/wörld","count":2}', $response->getContent());
    }
}
