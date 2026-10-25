<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Tag\Interface\Http\Controller;

use App\Tests\Integration\Shared\Trait\RunsInRolledBackTransaction;
use App\Tests\Support\Tokens;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

final class ListTagsActionTest extends KernelTestCase
{
    use RunsInRolledBackTransaction;

    public function testAnswers200WithEverySeededTagSortedByName(): void
    {
        $response = $this->get('/api/tags');

        self::assertSame(200, $response->getStatusCode());
        self::assertSame('application/json', $response->headers->get('Content-Type'));

        $body = json_decode((string) $response->getContent(), true);
        self::assertIsArray($body);
        self::assertSame(['tags'], array_keys($body));
        self::assertCount(200, $body['tags']);

        $sorted = $body['tags'];
        sort($sorted, SORT_STRING);
        self::assertSame($sorted, $body['tags']);
    }

    public function testAnswersFromTheRowsPostgresHoldsAtTheMoment(): void
    {
        $before = $this->tags();
        $this->connection->write('INSERT INTO tags (name) VALUES ($1)', ['0-just-added']);
        $after = $this->tags();

        self::assertSame(array_merge(['0-just-added'], $before), $after);
    }

    public function testNeedsNoToken(): void
    {
        self::assertSame(200, $this->get('/api/tags')->getStatusCode());
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function headersThatAreIgnored(): iterable
    {
        yield 'a garbage token' => ['Token garbage'];
        yield 'a valid token' => ['Token ' . Tokens::valid()];
        yield 'the wrong scheme' => ['Bearer abc'];
    }

    #[DataProvider('headersThatAreIgnored')]
    public function testIgnoresTheAuthorizationHeader(string $authorization): void
    {
        $response = $this->get('/api/tags', ['HTTP_AUTHORIZATION' => $authorization]);

        self::assertSame(200, $response->getStatusCode());
    }

    public function testAnswersAHeadRequestWithoutABody(): void
    {
        $response = self::$kernel->handle(Request::create('/api/tags', 'HEAD'));

        self::assertSame(200, $response->getStatusCode());
    }

    /**
     * @param array<string, string> $server
     */
    private function get(string $uri, array $server = []): Response
    {
        self::assertNotNull(self::$kernel);

        return self::$kernel->handle(Request::create($uri, 'GET', [], [], [], $server));
    }

    /**
     * @return list<string>
     */
    private function tags(): array
    {
        $body = json_decode((string) $this->get('/api/tags')->getContent(), true);
        self::assertIsArray($body);

        /** @var list<string> $tags */
        $tags = $body['tags'];

        return $tags;
    }
}
