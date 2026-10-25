<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Interface\Http\Kernel;

use App\Tests\Support\Tokens;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * How a request gets to its controller, and what comes back, through the application's own kernel.
 */
final class LeanHttpKernelTest extends KernelTestCase
{
    protected function setUp(): void
    {
        self::bootKernel();
    }

    public function testAControllerGetsTheRouteVariableTheRequestAndTheCallerWhateverTheOrderOfItsArguments(): void
    {
        $token = Tokens::valid('77');

        $response = $this->send('GET', '/__test/echo/hello?a=1&b[]=2', ['HTTP_AUTHORIZATION' => 'Token ' . $token]);

        self::assertSame(200, $response->getStatusCode());
        self::assertSame(
            ['word' => 'hello', 'method' => 'GET', 'query' => ['a' => '1', 'b' => ['2']], 'viewer' => 77],
            json_decode((string) $response->getContent(), true),
        );
    }

    public function testTheQueryStringIsNotPartOfThePathThatIsMatched(): void
    {
        self::assertSame(200, $this->send('GET', '/api/tags?limit=3&offset=1')->getStatusCode());
        self::assertSame(200, $this->send('GET', '/api/tags?')->getStatusCode());
    }

    public function testARouteVariableArrivesPercentDecoded(): void
    {
        $response = $this->send('GET', '/__test/echo/caf%C3%A9');

        self::assertSame('café', json_decode((string) $response->getContent(), true)['word'] ?? null);
    }

    public function testTheMethodDecidesTheRouteAndAMethodTheRouteDoesNotAllowIsA404(): void
    {
        self::assertSame('POST', json_decode((string) $this->send('POST', '/__test/echo/x')->getContent(), true)['method'] ?? null);

        $response = $this->send('PUT', '/__test/echo/x');

        self::assertSame(404, $response->getStatusCode());
        self::assertSame('{"errors":{"body":["not found"]}}', $response->getContent());
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function pathsThatMatchNothing(): iterable
    {
        yield 'a trailing slash' => ['/api/tags/'];
        yield 'a longer path' => ['/api/tags/extra/segments'];
        yield 'a doubled slash' => ['//api/tags'];
        yield 'an id that is not digits' => ['/api/articles/some-slug/comments/abc'];
        yield 'the encoded slash of a slug' => ['/api/articles/a%2Fb/comments/x/y'];
    }

    #[DataProvider('pathsThatMatchNothing')]
    public function testAPathThatMatchesNoRouteIsAJson404(string $uri): void
    {
        $response = $this->send('DELETE', $uri);

        self::assertSame(404, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));
    }

    public function testACommentIdOfDigitsReachesItsController(): void
    {
        // The route exists and the caller is not signed in: a 401 from the controller, not a 404 from the router.
        self::assertSame(401, $this->send('DELETE', '/api/articles/some-slug/comments/12')->getStatusCode());
    }

    public function testAControllerThatDoesNotReturnAResponseIsAJson500(): void
    {
        $log = tempnam(sys_get_temp_dir(), 'errlog');
        self::assertIsString($log);
        $previous = ini_set('error_log', $log);

        try {
            $response = $this->send('GET', '/__test/not-a-response');
        } finally {
            ini_set('error_log', (string) $previous);
        }

        self::assertSame(500, $response->getStatusCode());
        self::assertSame('{"errors":{"body":["internal server error"]}}', $response->getContent());
        self::assertStringContainsString('did not return a response', (string) file_get_contents($log));
        unlink($log);
    }

    public function testAJsonResponseNamesItsContentType(): void
    {
        self::assertSame('application/json', $this->send('GET', '/api/tags')->headers->get('Content-Type'));
    }

    /**
     * @param array<string, string> $server
     */
    private function send(string $method, string $uri, array $server = []): Response
    {
        self::assertNotNull(self::$kernel);

        return self::$kernel->handle(Request::create($uri, $method, [], [], [], $server));
    }
}
