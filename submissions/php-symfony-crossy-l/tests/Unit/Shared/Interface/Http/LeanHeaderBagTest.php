<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Interface\Http;

use App\Shared\Interface\Http\JsonResponder;
use App\Shared\Interface\Http\LeanHeaderBag;
use App\Shared\Interface\Http\Mapper\ErrorResponseMapper;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpFoundation\ResponseHeaderBag;

final class LeanHeaderBagTest extends TestCase
{
    public function testItHoldsTheContentTypeAndTheNoCacheDirectiveAndNothingElse(): void
    {
        $headers = new LeanHeaderBag('application/json');

        self::assertSame(['Cache-Control' => ['no-cache, private'], 'Content-Type' => ['application/json']], $headers->allPreserveCase());
        self::assertFalse($headers->has('Date'));
    }

    public function testWithoutAContentTypeItHasNone(): void
    {
        $headers = new LeanHeaderBag(null);

        self::assertFalse($headers->has('Content-Type'));
        self::assertSame('no-cache, private', $headers->get('Cache-Control'));
    }

    public function testItHasTheSameCacheControlTheFrameworksBagWorksOut(): void
    {
        self::assertSame((new ResponseHeaderBag())->get('Cache-Control'), (new LeanHeaderBag(null))->get('Cache-Control'));
    }

    public function testItBehavesAsABagWhenAnotherHeaderIsSet(): void
    {
        $headers = new LeanHeaderBag('application/json');

        $headers->set('X-Probe', 'one');
        $headers->set('Content-Type', 'text/plain');
        $headers->set('Cache-Control', 'public, max-age=60');

        self::assertSame('one', $headers->get('X-Probe'));
        self::assertSame('text/plain', $headers->get('content-type'));
        self::assertSame((new ResponseHeaderBag(['Cache-Control' => 'public, max-age=60']))->get('Cache-Control'), $headers->get('Cache-Control'));
        self::assertSame(['Cache-Control', 'Content-Type', 'X-Probe'], array_keys($headers->allPreserveCase()));
    }

    public function testTheJsonResponderUsesItForTheBodyAndForTheNoContentAnswer(): void
    {
        $json = new JsonResponder();

        $body = $json->respond((new ErrorResponseMapper())->toResponse(['nope']), Response::HTTP_UNPROCESSABLE_ENTITY);
        $noContent = $json->noContent();

        self::assertSame(422, $body->getStatusCode());
        self::assertSame('application/json', $body->headers->get('Content-Type'));
        self::assertSame('{"errors":{"body":["nope"]}}', $body->getContent());
        self::assertSame(204, $noContent->getStatusCode());
        self::assertFalse($noContent->headers->has('Content-Type'));
        self::assertSame('', $noContent->getContent());
    }
}
