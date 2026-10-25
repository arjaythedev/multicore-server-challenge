<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http;

use Symfony\Component\HttpFoundation\Response;

/**
 * Turns a Response object into an HTTP response with a JSON body.
 */
final class JsonResponder
{
    private const int ENCODING = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR;

    public function respond(object $body, int $status): Response
    {
        return new Response(json_encode($body, self::ENCODING), $status, new LeanHeaderBag('application/json'));
    }

    /**
     * A 204: no body and no Content-Type.
     */
    public function noContent(): Response
    {
        return new Response(null, Response::HTTP_NO_CONTENT, new LeanHeaderBag(null));
    }
}
