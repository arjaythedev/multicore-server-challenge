<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Server;

use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Throwable;

/**
 * Takes one request through the kernel and says what to write back.
 * A throwable that escapes the kernel is answered with a JSON 500, so no request ends its worker.
 */
final readonly class RequestHandler
{
    private const string FAILURE_BODY = '{"errors":{"body":["internal server error"]}}';

    public function __construct(
        private HttpKernelInterface $kernel,
    ) {
    }

    /**
     * @param array<string, mixed> $server
     * @param array<string, string> $headers
     * @param array<array-key, mixed> $query
     */
    public function handle(array $server, array $headers, array $query, string $body): Reply
    {
        try {
            $response = $this->kernel->handle(RequestFactory::create($server, $headers, $query, $body));

            return new Reply($response->getStatusCode(), self::headersOf($response), (string) $response->getContent());
        } catch (Throwable $failure) {
            error_log((string) $failure);

            return new Reply(Response::HTTP_INTERNAL_SERVER_ERROR, [['Content-Type', 'application/json']], self::FAILURE_BODY);
        }
    }

    /**
     * The header names are in lower case; the server writes them out in their usual form.
     *
     * @return list<array{string, string}>
     */
    private static function headersOf(Response $response): array
    {
        $headers = [];

        foreach ($response->headers->all() as $name => $values) {
            foreach ($values as $value) {
                $headers[] = [$name, (string) $value];
            }
        }

        return $headers;
    }
}
