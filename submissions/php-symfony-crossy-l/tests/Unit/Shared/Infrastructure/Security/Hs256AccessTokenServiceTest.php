<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Security;

use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Infrastructure\Security\Hs256AccessTokenService;
use App\Tests\Support\Tokens;
use InvalidArgumentException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class Hs256AccessTokenServiceTest extends TestCase
{
    private Hs256AccessTokenService $service;

    protected function setUp(): void
    {
        $this->service = new Hs256AccessTokenService(Tokens::SECRET);
    }

    public function testATokenItIssuedVerifiesAsTheSameUser(): void
    {
        self::assertSame(1234, $this->service->verify($this->service->issue(1234)));
    }

    public function testAnIssuedTokenCarriesTheDocumentedClaims(): void
    {
        $before = time();
        $token = $this->service->issue(42);

        [$header, $payload] = explode('.', $token);
        $claims = json_decode((string) base64_decode(strtr($payload, '-_', '+/'), true), true, 8, JSON_THROW_ON_ERROR);

        self::assertSame(['alg' => 'HS256', 'typ' => 'JWT'], json_decode((string) base64_decode(strtr($header, '-_', '+/'), true), true, 8, JSON_THROW_ON_ERROR));
        self::assertSame(['sub', 'iat', 'exp'], array_keys($claims));
        self::assertSame('42', $claims['sub']);
        self::assertGreaterThanOrEqual($before, $claims['iat']);
        self::assertSame(30 * 24 * 3600, $claims['exp'] - $claims['iat']);
    }

    public function testAcceptsATokenMintedByAnotherImplementationUnderTheRawSecret(): void
    {
        self::assertSame(7, $this->service->verify(Tokens::valid('7')));
    }

    public function testAcceptsAnExpiryGivenAsAFloat(): void
    {
        $token = Tokens::mint(['sub' => '9', 'exp' => time() + 100.5]);

        self::assertSame(9, $this->service->verify($token));
    }

    public function testChecksTheExpiryOnEveryCall(): void
    {
        $token = Tokens::mint(['sub' => '9', 'exp' => time() + 2]);
        self::assertSame(9, $this->service->verify($token));

        sleep(3);

        $this->expectException(UnauthorizedException::class);
        $this->service->verify($token);
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function refusedTokens(): iterable
    {
        $now = time();
        $claims = ['sub' => '7', 'iat' => $now, 'exp' => $now + 3600];
        $valid = Tokens::mint($claims);
        [$header, $payload] = explode('.', $valid);

        yield 'empty' => [''];
        yield 'garbage' => ['not.a.jwt'];
        yield 'one segment' => ['abc'];
        yield 'two segments' => [$header . '.' . $payload];
        yield 'four segments' => [$valid . '.extra'];
        yield 'no signature' => [$header . '.' . $payload . '.'];
        yield 'signed with another secret' => [Tokens::mint($claims, Tokens::SECRET . '-wrong')];
        yield 'payload changed after signing' => [
            $header . '.' . Tokens::encode((string) json_encode([...$claims, 'sub' => '8'])) . '.' . explode('.', $valid)[2],
        ];
        yield 'signature with padding' => [$valid . '='];
        yield 'algorithm none' => [Tokens::mint($claims, '', 'none')];
        yield 'algorithm HS512 signed correctly' => [Tokens::mint($claims, Tokens::SECRET, 'HS512')];
        yield 'header says HS512 under an HS256 signature' => [
            (static function () use ($claims): string {
                $header = Tokens::encode((string) json_encode(['alg' => 'HS512', 'typ' => 'JWT']));
                $payload = Tokens::encode((string) json_encode($claims));

                return $header . '.' . $payload . '.' . Tokens::encode(hash_hmac('sha256', $header . '.' . $payload, Tokens::SECRET, true));
            })(),
        ];
        yield 'expired a second ago' => [Tokens::mint([...$claims, 'exp' => $now - 1])];
        yield 'expired ten days ago' => [Tokens::mint([...$claims, 'iat' => $now - 40 * 86400, 'exp' => $now - 10 * 86400])];
        yield 'expiring now' => [Tokens::mint([...$claims, 'exp' => $now])];
        yield 'no expiry' => [Tokens::mint(['sub' => '7', 'iat' => $now])];
        yield 'expiry a string' => [Tokens::mint([...$claims, 'exp' => (string) ($now + 3600)])];
        yield 'expiry null' => [Tokens::mint([...$claims, 'exp' => null])];
        yield 'no subject' => [Tokens::mint(['iat' => $now, 'exp' => $now + 3600])];
        yield 'subject a number' => [Tokens::mint([...$claims, 'sub' => 7])];
        yield 'subject a word' => [Tokens::mint([...$claims, 'sub' => 'abc'])];
        yield 'subject empty' => [Tokens::mint([...$claims, 'sub' => ''])];
        yield 'subject zero' => [Tokens::mint([...$claims, 'sub' => '0'])];
        yield 'subject negative' => [Tokens::mint([...$claims, 'sub' => '-3'])];
        yield 'subject with a sign' => [Tokens::mint([...$claims, 'sub' => '+3'])];
        yield 'subject with a fraction' => [Tokens::mint([...$claims, 'sub' => '3.5'])];
        yield 'subject beyond bigint' => [Tokens::mint([...$claims, 'sub' => '99999999999999999999'])];
        yield 'subject an array' => [Tokens::mint([...$claims, 'sub' => ['7']])];
        yield 'claims not an object' => [Tokens::mint([1, 2, 3])];
    }

    #[DataProvider('refusedTokens')]
    public function testRefusesAToken(string $token): void
    {
        $this->expectException(UnauthorizedException::class);

        $this->service->verify($token);
    }

    public function testRefusesAnEmptySecret(): void
    {
        $this->expectException(InvalidArgumentException::class);

        new Hs256AccessTokenService('');
    }
}
