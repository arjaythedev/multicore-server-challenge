<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Interface\Http\Caller;

use App\Tests\Support\Tokens;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * The caller a controller receives, through the whole kernel: routing, the caller factory, the controller and
 * the error responder.
 */
final class CallerContextTest extends KernelTestCase
{
    protected function setUp(): void
    {
        self::bootKernel();
    }

    public function testNoTokenOnARouteWhereSigningInIsOptionalIsAnAnonymousViewer(): void
    {
        $response = $this->send('GET', '/__test/optional');

        self::assertSame(200, $response->getStatusCode());
        self::assertSame(['viewer' => 0, 'token' => null], $this->json($response));
    }

    public function testAValidTokenIsTheUserItNames(): void
    {
        $token = Tokens::valid('42');

        $response = $this->send('GET', '/__test/optional', 'Token ' . $token);

        self::assertSame(['viewer' => 42, 'token' => $token], $this->json($response));
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function headersThatAreNotAValidToken(): iterable
    {
        $claims = ['sub' => '7', 'iat' => time(), 'exp' => time() + 3600];

        yield 'garbage' => ['Token garbage'];
        yield 'the Bearer scheme' => ['Bearer ' . Tokens::valid()];
        yield 'a bad signature' => ['Token ' . Tokens::mint($claims, 'another-secret')];
        yield 'algorithm none' => ['Token ' . Tokens::mint($claims, '', 'none')];
        yield 'algorithm HS512' => ['Token ' . Tokens::mint($claims, Tokens::SECRET, 'HS512')];
        yield 'expired' => ['Token ' . Tokens::mint([...$claims, 'exp' => time() - 60])];
    }

    #[DataProvider('headersThatAreNotAValidToken')]
    public function testABadTokenIsA401EvenWhereSigningInIsOptional(string $authorization): void
    {
        $response = $this->send('GET', '/__test/optional', $authorization);

        self::assertSame(401, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));
        $body = $this->json($response);
        self::assertSame(['errors'], array_keys($body));
        self::assertIsArray($body['errors']);
        self::assertSame(['body'], array_keys($body['errors']));
        self::assertIsArray($body['errors']['body']);
        self::assertCount(1, $body['errors']['body']);
        self::assertNotSame('', $body['errors']['body'][0]);
    }

    public function testARouteThatNeedsSigningInRefusesAnAnonymousCaller(): void
    {
        $response = $this->send('GET', '/__test/required');

        self::assertSame(401, $response->getStatusCode());
        self::assertSame('{"errors":{"body":["authentication required"]}}', $response->getContent());
    }

    public function testARouteThatNeedsSigningInServesASignedInCaller(): void
    {
        $response = $this->send('GET', '/__test/required', 'Token ' . Tokens::valid('5'));

        self::assertSame(['viewer' => 5], $this->json($response));
    }

    private function send(string $method, string $uri, ?string $authorization = null): Response
    {
        self::assertNotNull(self::$kernel);
        $server = $authorization === null ? [] : ['HTTP_AUTHORIZATION' => $authorization];

        return self::$kernel->handle(Request::create($uri, $method, [], [], [], $server));
    }

    /**
     * @return array<string, mixed>
     */
    private function json(Response $response): array
    {
        $body = json_decode((string) $response->getContent(), true);
        self::assertIsArray($body);

        /** @var array<string, mixed> $body */
        return $body;
    }
}
