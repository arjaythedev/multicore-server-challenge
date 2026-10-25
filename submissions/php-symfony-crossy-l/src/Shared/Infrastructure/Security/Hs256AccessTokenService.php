<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Security;

use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Security\AccessTokenServiceInterface;
use InvalidArgumentException;
use JsonException;
use SensitiveParameter;

/**
 * JSON Web Tokens signed with HMAC-SHA256, carrying {"sub": "<user id>", "iat": <now>, "exp": <now + 30 days>}.
 *
 * Accepted when the signature is the HMAC of the first two segments, the header names HS256, the expiry is in the
 * future and the subject is a user id. Every call checks all of it; the claims are read only after the signature.
 */
final class Hs256AccessTokenService implements AccessTokenServiceInterface
{
    private const string ALGORITHM = 'HS256';

    private const string HASH = 'sha256';

    private const int LIFETIME_SECONDS = 30 * 24 * 3600;

    private readonly string $encodedHeader;

    public function __construct(
        #[SensitiveParameter]
        private readonly string $secret,
    ) {
        if ($secret === '') {
            throw new InvalidArgumentException('The token secret must not be empty.');
        }

        $this->encodedHeader = self::encode('{"alg":"' . self::ALGORITHM . '","typ":"JWT"}');
    }

    public function verify(string $token): int
    {
        $segments = explode('.', $token, 4);

        if (\count($segments) !== 3) {
            throw self::invalid();
        }

        [$header, $payload, $signature] = $segments;

        if (!hash_equals($this->sign($header . '.' . $payload), $signature)) {
            throw self::invalid();
        }

        if ((self::decodeObject($header)['alg'] ?? null) !== self::ALGORITHM) {
            throw self::invalid();
        }

        $claims = self::decodeObject($payload);
        $expiry = $claims['exp'] ?? null;

        if ((!\is_int($expiry) && !\is_float($expiry)) || $expiry <= time()) {
            throw self::invalid();
        }

        return self::userIdOf($claims['sub'] ?? null);
    }

    public function issue(int $userId): string
    {
        $issuedAt = time();
        $payload = self::encode(json_encode(
            ['sub' => (string) $userId, 'iat' => $issuedAt, 'exp' => $issuedAt + self::LIFETIME_SECONDS],
            JSON_THROW_ON_ERROR,
        ));
        $signed = $this->encodedHeader . '.' . $payload;

        return $signed . '.' . $this->sign($signed);
    }

    private function sign(string $signed): string
    {
        return self::encode(hash_hmac(self::HASH, $signed, $this->secret, true));
    }

    /**
     * The subject is the user id as a decimal string; a number, a word or zero names no user.
     */
    private static function userIdOf(mixed $subject): int
    {
        if (!\is_string($subject) || !ctype_digit($subject)) {
            throw self::invalid();
        }

        $userId = filter_var($subject, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);

        if ($userId === false) {
            throw self::invalid();
        }

        return $userId;
    }

    /**
     * @return array<mixed>
     */
    private static function decodeObject(string $segment): array
    {
        $json = base64_decode(strtr($segment, '-_', '+/'), true);

        if ($json === false) {
            throw self::invalid();
        }

        try {
            $decoded = json_decode($json, true, 8, JSON_THROW_ON_ERROR);
        } catch (JsonException) {
            throw self::invalid();
        }

        if (!\is_array($decoded)) {
            throw self::invalid();
        }

        return $decoded;
    }

    private static function encode(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    private static function invalid(): UnauthorizedException
    {
        return UnauthorizedException::withMessage('invalid token');
    }
}
