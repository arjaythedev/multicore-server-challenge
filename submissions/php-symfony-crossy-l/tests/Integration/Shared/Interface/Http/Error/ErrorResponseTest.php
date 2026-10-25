<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Interface\Http\Error;

use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * What a client gets back for the faults the routes and the code can cause, through the whole kernel.
 */
final class ErrorResponseTest extends KernelTestCase
{
    protected function setUp(): void
    {
        self::bootKernel();
    }

    /**
     * @return iterable<string, array{string, string}>
     */
    public static function routesThatDoNotExist(): iterable
    {
        yield 'an unknown path' => ['GET', '/api/nothing-here'];
        yield 'the root' => ['GET', '/'];
        yield 'a known path, another method' => ['POST', '/api/tags'];
        yield 'a known path, DELETE' => ['DELETE', '/api/tags'];
    }

    #[DataProvider('routesThatDoNotExist')]
    public function testAnUnknownRouteIsAJson404(string $method, string $uri): void
    {
        $response = $this->send($method, $uri);

        self::assertSame(404, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));
        self::assertSame('{"errors":{"body":["not found"]}}', $response->getContent());
    }

    public function testAnUnexpectedExceptionIsAJson500AndTheKernelServesTheNextRequest(): void
    {
        $log = tempnam(sys_get_temp_dir(), 'errlog');
        self::assertIsString($log);
        $previous = ini_set('error_log', $log);

        try {
            $response = $this->send('GET', '/__test/boom');
        } finally {
            ini_set('error_log', (string) $previous);
        }

        self::assertSame(500, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));
        self::assertSame('{"errors":{"body":["internal server error"]}}', $response->getContent());
        self::assertStringContainsString('something nobody expected', (string) file_get_contents($log));
        unlink($log);

        self::assertSame(200, $this->send('GET', '/__test/optional')->getStatusCode());
    }

    private function send(string $method, string $uri, ?string $authorization = null): Response
    {
        self::assertNotNull(self::$kernel);
        $server = $authorization === null ? [] : ['HTTP_AUTHORIZATION' => $authorization];

        return self::$kernel->handle(Request::create($uri, $method, [], [], [], $server));
    }
}
