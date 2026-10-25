<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Persistence\Pg\Batch;

use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class BatchedReadTest extends TestCase
{
    public function testTheStatementRunsTheBodyOncePerRequestOverArraysReadSideBySide(): void
    {
        $read = new BatchedRead('SELECT $2 AS slug, $1 AS viewer WHERE $1 > 0', ['bigint', 'text']);

        self::assertSame(
            'SELECT q.ord, b.* FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS q(p1, p2, ord)'
            . ' CROSS JOIN LATERAL (SELECT q.p2 AS slug, q.p1 AS viewer WHERE q.p1 > 0) b',
            $read->sql,
        );
    }

    public function testTheParametersOfTheRequestsBecomeOneArrayEach(): void
    {
        self::assertSame(['{"7","9"}', '{"a","b"}'], BatchedRead::arrays([[7, 'a'], [9, 'b']]));
    }

    public function testAnElementIsQuotedSoThatNothingInItIsRead(): void
    {
        self::assertSame(['{"a\"b","c\\\\d","NULL","{x}","a, b"}'], BatchedRead::arrays([['a"b'], ['c\\d'], ['NULL'], ['{x}'], ['a, b']]));
    }

    public function testAnElementIsCutAtANulByteAsTheClientLibraryCutsAParameter(): void
    {
        self::assertSame(['{"ab","","c"}'], BatchedRead::arrays([["ab\0cd"], ["\0"], ['c']]));
    }

    public function testNothingIsNullInABatch(): void
    {
        $this->expectException(InvalidArgumentException::class);

        BatchedRead::arrays([[1, null]]);
    }
}
