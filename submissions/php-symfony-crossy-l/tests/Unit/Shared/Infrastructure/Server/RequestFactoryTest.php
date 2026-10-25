<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Server;

use App\Shared\Infrastructure\Server\RequestFactory;
use PHPUnit\Framework\TestCase;

final class RequestFactoryTest extends TestCase
{
    public function testCarriesTheMethodTheUriTheQueryAndTheBody(): void
    {
        $request = RequestFactory::create(
            ['request_method' => 'POST', 'request_uri' => '/api/articles', 'query_string' => 'a=1&b[]=2', 'server_protocol' => 'HTTP/1.1'],
            [],
            ['a' => '1', 'b' => ['2']],
            '{"article":{}}',
        );

        self::assertSame('POST', $request->getMethod());
        self::assertSame('/api/articles?a=1&b[]=2', $request->getRequestUri());
        self::assertSame(['a' => '1', 'b' => ['2']], $request->query->all());
        self::assertSame('{"article":{}}', $request->getContent());
    }

    public function testAUriWithoutAQueryStringHasNoQuestionMark(): void
    {
        $request = RequestFactory::create(['request_method' => 'GET', 'request_uri' => '/api/tags'], [], [], '');

        self::assertSame('/api/tags', $request->getRequestUri());
    }

    public function testCarriesTheHeadersTheApplicationReads(): void
    {
        $request = RequestFactory::create(
            ['request_method' => 'POST', 'request_uri' => '/'],
            ['authorization' => 'Token abc', 'content-type' => 'application/json', 'content-length' => '2', 'accept' => 'text/html', 'x-other' => 'ignored'],
            [],
            '{}',
        );

        self::assertSame('Token abc', $request->headers->get('Authorization'));
        self::assertSame('application/json', $request->headers->get('Content-Type'));
        self::assertSame('2', $request->headers->get('Content-Length'));
        self::assertNull($request->headers->get('X-Other'));
        self::assertNull($request->headers->get('Accept'));
    }

    public function testNoAuthorizationHeaderIsNone(): void
    {
        self::assertNull(RequestFactory::create(['request_method' => 'GET', 'request_uri' => '/'], [], [], '')->headers->get('Authorization'));
    }

    public function testTheMethodDefaultsToGetAndTheUriToTheRoot(): void
    {
        $request = RequestFactory::create([], [], [], '');

        self::assertSame('GET', $request->getMethod());
        self::assertSame('/', $request->getRequestUri());
    }
}
