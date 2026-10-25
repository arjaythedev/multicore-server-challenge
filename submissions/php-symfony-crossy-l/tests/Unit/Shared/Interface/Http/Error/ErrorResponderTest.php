<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Interface\Http\Error;

use App\Shared\Domain\Model\Exception\ForbiddenException;
use App\Shared\Domain\Model\Exception\NotFoundException;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Model\Exception\ValidationException;
use App\Shared\Interface\Http\ErrorResponder;
use App\Shared\Interface\Http\JsonResponder;
use App\Shared\Interface\Http\Mapper\ErrorResponseMapper;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use RuntimeException;
use Symfony\Component\HttpFoundation\Exception\SuspiciousOperationException;
use Symfony\Component\HttpKernel\Exception\BadRequestHttpException;
use Symfony\Component\Routing\Exception\MethodNotAllowedException;
use Symfony\Component\Routing\Exception\ResourceNotFoundException;
use Throwable;

final class ErrorResponderTest extends TestCase
{
    private ErrorResponder $responder;

    protected function setUp(): void
    {
        $this->responder = new ErrorResponder(new ErrorResponseMapper(), new JsonResponder());
    }

    /**
     * @return iterable<string, array{Throwable, int, list<string>}>
     */
    public static function answers(): iterable
    {
        yield 'not found' => [NotFoundException::withMessage('no such article'), 404, ['no such article']];
        yield 'forbidden' => [ForbiddenException::withMessage('not your article'), 403, ['not your article']];
        yield 'unauthorized' => [UnauthorizedException::withMessage('invalid token'), 401, ['invalid token']];
        yield 'validation, one message' => [ValidationException::withMessage('title is required'), 422, ['title is required']];
        yield 'validation, several' => [ValidationException::withErrors('invalid', ['a', 'b']), 422, ['a', 'b']];
        yield 'unknown route' => [new ResourceNotFoundException('No routes found for "/secret/path".'), 404, ['not found']];
        yield 'known route, other method' => [new MethodNotAllowedException(['GET']), 404, ['not found']];
        yield 'a request the framework refuses' => [new SuspiciousOperationException('Invalid Host "evil"'), 400, ['request error']];
        yield 'another HTTP error' => [new BadRequestHttpException('detail'), 400, ['request error']];
    }

    /**
     * @param list<string> $messages
     */
    #[DataProvider('answers')]
    public function testAnswersWithTheJsonErrorBody(Throwable $error, int $status, array $messages): void
    {
        $response = $this->responder->respond($error);

        self::assertSame($status, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));
        self::assertSame(['errors' => ['body' => $messages]], json_decode((string) $response->getContent(), true));
    }

    public function testAnythingElseIsA500ThatKeepsItsDetailInTheLog(): void
    {
        $log = tempnam(sys_get_temp_dir(), 'errlog');
        self::assertIsString($log);
        $previous = ini_set('error_log', $log);

        try {
            $response = $this->responder->respond(new RuntimeException('connection string postgres://user:secret@host/db'));
        } finally {
            ini_set('error_log', (string) $previous);
        }

        self::assertSame(500, $response->getStatusCode());
        self::assertSame('{"errors":{"body":["internal server error"]}}', $response->getContent());
        self::assertStringContainsString('postgres://user:secret@host/db', (string) file_get_contents($log));
        unlink($log);
    }
}
