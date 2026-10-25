<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Server;

use Symfony\Component\HttpFoundation\Request;

/**
 * Makes the framework's Request from what Swoole reports about a request: its server variables and headers, with
 * lower-case names, the parsed query string, and the body.
 */
final class RequestFactory
{
    /** Request headers the application reads, by their lower-case names, and the server variable each becomes. */
    private const array HEADERS = [
        'authorization' => 'HTTP_AUTHORIZATION',
        'content-type' => 'CONTENT_TYPE',
        'content-length' => 'CONTENT_LENGTH',
    ];

    /**
     * @param array<string, mixed> $server request_method, request_uri (the path, without the query), query_string, server_protocol
     * @param array<string, string> $headers
     * @param array<array-key, mixed> $query
     */
    public static function create(array $server, array $headers, array $query, string $body): Request
    {
        $path = self::text($server, 'request_uri', '/');
        $queryString = self::text($server, 'query_string', '');

        $variables = [
            'REQUEST_METHOD' => self::text($server, 'request_method', 'GET'),
            'REQUEST_URI' => $queryString === '' ? $path : $path . '?' . $queryString,
            'QUERY_STRING' => $queryString,
            'SERVER_PROTOCOL' => self::text($server, 'server_protocol', 'HTTP/1.1'),
        ];

        foreach (self::HEADERS as $name => $variable) {
            if (isset($headers[$name])) {
                $variables[$variable] = $headers[$name];
            }
        }

        return new Request($query, [], [], [], [], $variables, $body);
    }

    /**
     * @param array<string, mixed> $server
     */
    private static function text(array $server, string $key, string $default): string
    {
        $value = $server[$key] ?? $default;

        return \is_string($value) ? $value : $default;
    }
}
