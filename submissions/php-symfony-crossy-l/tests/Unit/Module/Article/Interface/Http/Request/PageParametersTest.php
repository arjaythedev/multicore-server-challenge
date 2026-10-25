<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Interface\Http\Request;

use App\Module\Article\Interface\Http\Request\PageParameters;
use App\Shared\Domain\Model\Exception\ValidationException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;

final class PageParametersTest extends TestCase
{
    /** @return iterable<string, array{string, int, int}> */
    public static function validPages(): iterable
    {
        yield 'defaults' => ['', 20, 0];
        yield 'leading zeros' => ['?limit=001&offset=0002', 1, 2];
        yield 'maximum' => ['?limit=100&offset=9223372036854775807', 100, PHP_INT_MAX];
    }

    #[DataProvider('validPages')]
    public function testReadsDecimalPagination(string $query, int $limit, int $offset): void
    {
        $page = PageParameters::fromRequest(Request::create('/api/articles' . $query));

        self::assertSame($limit, $page->limit);
        self::assertSame($offset, $page->offset);
    }

    /** @return iterable<string, array{string}> */
    public static function invalidPages(): iterable
    {
        foreach (['limit=0', 'limit=101', 'limit=', 'limit[]=1', 'limit=1.5', 'limit=+1', 'offset=-1', 'offset=1e3', 'offset=9223372036854775808', 'offset[]=1', 'offset='] as $query) {
            yield $query => [$query];
        }
    }

    #[DataProvider('invalidPages')]
    public function testRefusesInvalidAndOverflowingPagination(string $query): void
    {
        $this->expectException(ValidationException::class);
        PageParameters::fromRequest(Request::create('/api/articles?' . $query));
    }
}
