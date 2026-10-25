<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Server;

use App\Shared\Infrastructure\Server\RequestHandler;
use App\Shared\Interface\Http\LeanHeaderBag;
use App\Tests\Support\RecordingKernel;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Response;

final class RequestHandlerTest extends TestCase
{
    private string $errorLog;

    private string|false $previousErrorLog;

    protected function setUp(): void
    {
        // What the handler reports about a failed request goes to a file here, not to the test's error output.
        $this->errorLog = (string) tempnam(sys_get_temp_dir(), 'handler-test');
        $this->previousErrorLog = ini_set('error_log', $this->errorLog);
    }

    protected function tearDown(): void
    {
        ini_set('error_log', (string) $this->previousErrorLog);
        @unlink($this->errorLog);
    }

    public function testAnswersWithTheKernelsStatusHeadersAndBody(): void
    {
        $reply = (new RequestHandler(new RecordingKernel()))->handle(['request_method' => 'GET', 'request_uri' => '/first'], [], [], '');

        self::assertSame(200, $reply->status);
        self::assertSame('/first', $reply->body);
    }

    public function testCarriesEveryHeaderOfTheResponse(): void
    {
        $kernel = new class () implements \Symfony\Component\HttpKernel\HttpKernelInterface {
            public function handle(\Symfony\Component\HttpFoundation\Request $request, int $type = self::MAIN_REQUEST, bool $catch = true): Response
            {
                return new Response('{}', 201, new LeanHeaderBag('application/json'));
            }
        };

        $reply = (new RequestHandler($kernel))->handle(['request_method' => 'POST', 'request_uri' => '/'], [], [], '');

        self::assertSame(201, $reply->status);
        self::assertContains(['content-type', 'application/json'], $reply->headers);
        self::assertContains(['cache-control', 'no-cache, private'], $reply->headers);
    }

    public function testAThrowableThatEscapesTheKernelIsAJson500AndIsLogged(): void
    {
        $reply = (new RequestHandler(new RecordingKernel()))->handle(['request_method' => 'GET', 'request_uri' => '/boom'], [], [], '');

        self::assertSame(500, $reply->status);
        self::assertSame('{"errors":{"body":["internal server error"]}}', $reply->body);
        self::assertContains(['Content-Type', 'application/json'], $reply->headers);
        self::assertStringContainsString('boom', (string) file_get_contents($this->errorLog));
    }

    public function testTheNextRequestIsServedAfterAFailure(): void
    {
        $handler = new RequestHandler(new RecordingKernel());

        $handler->handle(['request_method' => 'GET', 'request_uri' => '/boom'], [], [], '');
        $reply = $handler->handle(['request_method' => 'GET', 'request_uri' => '/after'], [], [], '');

        self::assertSame(200, $reply->status);
        self::assertSame('/after', $reply->body);
    }
}
