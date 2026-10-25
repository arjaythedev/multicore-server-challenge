<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http;

use Symfony\Component\HttpFoundation\ResponseHeaderBag;

/**
 * The headers of a response of this API: the content type, if it has one, and that nothing may be cached.
 * Given the finished Cache-Control value; the date is left to the server.
 */
final class LeanHeaderBag extends ResponseHeaderBag
{
    public function __construct(?string $contentType)
    {
        // the parent constructor would compute the headers fixed here
        $this->headers = ['cache-control' => ['no-cache, private']];
        $this->headerNames = ['cache-control' => 'Cache-Control'];
        $this->cacheControl = ['no-cache' => true, 'private' => true];
        $this->computedCacheControl = ['no-cache' => true, 'private' => true];

        if ($contentType !== null) {
            $this->headers['content-type'] = [$contentType];
            $this->headerNames['content-type'] = 'Content-Type';
        }
    }
}
