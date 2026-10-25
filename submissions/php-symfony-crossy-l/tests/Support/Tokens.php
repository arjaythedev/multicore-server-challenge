<?php

declare(strict_types=1);

namespace App\Tests\Support;

use JsonException;

/**
 * Tokens built by hand, the way a client that is not this server would build them, so that the
 * tests can forge exactly the faults the server has to refuse.
 */
final class Tokens
{
    /** The secret the benchmark gives the server. It is shorter than 32 bytes. */
    public const string SECRET = 'multicore-server-challenge';

    /**
     * @param array<mixed> $claims
     *
     * @throws JsonException
     */
    public static function mint(array $claims, string $secret = self::SECRET, string $algorithm = 'HS256'): string
    {
        $header = self::encode(json_encode(['alg' => $algorithm, 'typ' => 'JWT'], JSON_THROW_ON_ERROR));
        $payload = self::encode(json_encode($claims, JSON_THROW_ON_ERROR));
        $hash = ['HS256' => 'sha256', 'HS512' => 'sha512'][$algorithm] ?? null;
        $signature = $hash === null ? '' : hash_hmac($hash, $header . '.' . $payload, $secret, true);

        return $header . '.' . $payload . '.' . self::encode($signature);
    }

    /**
     * A token the server accepts for the user.
     *
     * @throws JsonException
     */
    public static function valid(int|string $subject = '7'): string
    {
        $now = time();

        return self::mint(['sub' => (string) $subject, 'iat' => $now, 'exp' => $now + 3600]);
    }

    public static function encode(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }
}
