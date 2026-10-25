<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Interface\Http\Caller;

use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Infrastructure\Security\Hs256AccessTokenService;
use App\Shared\Interface\Http\CallerContextFactory;
use App\Tests\Support\Tokens;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;

final class CallerContextFactoryTest extends TestCase
{
    private CallerContextFactory $factory;

    protected function setUp(): void
    {
        $this->factory = new CallerContextFactory(new Hs256AccessTokenService(Tokens::SECRET));
    }

    public function testNoHeaderIsAnAnonymousCaller(): void
    {
        $caller = $this->resolve(new Request());

        self::assertTrue($caller->isAnonymous());
        self::assertSame(0, $caller->getViewerId());
    }

    public function testAnEmptyHeaderIsAnAnonymousCaller(): void
    {
        self::assertTrue($this->resolve($this->requestWith(''))->isAnonymous());
    }

    public function testAValidTokenIsTheUserItNamesAndKeepsTheTokenAsPresented(): void
    {
        $token = Tokens::valid('314');

        $caller = $this->resolve($this->requestWith('Token ' . $token));

        self::assertFalse($caller->isAnonymous());
        self::assertSame(314, $caller->getViewerId());
        self::assertSame($token, $caller->getToken());
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function refusedHeaders(): iterable
    {
        $now = time();
        $claims = ['sub' => '7', 'iat' => $now, 'exp' => $now + 3600];
        $valid = Tokens::mint($claims);

        yield 'the Bearer scheme' => ['Bearer ' . $valid];
        yield 'a lowercase scheme' => ['token ' . $valid];
        yield 'no scheme' => [$valid];
        yield 'a scheme and no token' => ['Token '];
        yield 'the scheme alone' => ['Token'];
        yield 'a token behind two spaces' => ['Token  ' . $valid];
        yield 'garbage' => ['Token not.a.jwt'];
        yield 'a bad signature' => ['Token ' . Tokens::mint($claims, Tokens::SECRET . '-wrong')];
        yield 'algorithm none' => ['Token ' . Tokens::mint($claims, '', 'none')];
        yield 'algorithm HS512' => ['Token ' . Tokens::mint($claims, Tokens::SECRET, 'HS512')];
        yield 'an expired token' => ['Token ' . Tokens::mint([...$claims, 'exp' => $now - 3600])];
    }

    #[DataProvider('refusedHeaders')]
    public function testAHeaderThatIsPresentButNotAValidTokenIsRefused(string $header): void
    {
        $this->expectException(UnauthorizedException::class);

        $this->resolve($this->requestWith($header));
    }

    private function requestWith(string $authorization): Request
    {
        $request = new Request();
        $request->headers->set('Authorization', $authorization);

        return $request;
    }

    private function resolve(Request $request): CallerContext
    {
        return $this->factory->fromRequest($request);
    }
}
