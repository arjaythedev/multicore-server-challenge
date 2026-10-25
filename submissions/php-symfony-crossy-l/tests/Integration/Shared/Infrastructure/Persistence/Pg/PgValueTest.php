<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Infrastructure\Persistence\Pg\PgValue;
use App\Tests\Integration\Shared\AbstractControllerTestCase;
use PHPUnit\Framework\Attributes\DataProvider;

final class PgValueTest extends AbstractControllerTestCase
{
    /** @return iterable<string, array{list<string>}> */
    public static function textArrays(): iterable
    {
        yield 'empty' => [[]];
        yield 'plain' => [['a', 'b']];
        yield 'bare names with digits, hyphens and plus signs' => [['react-native', 'web3', 'c++', 'node.js', '100%']];
        yield 'escaped' => [['a,b', 'quote"', 'back\\slash', '{braces}', '', 'NULL', 'null', ' space ', 'é', "line\nbreak"]];
    }

    #[DataProvider('textArrays')]
    public function testArrayParametersSurviveAPostgresRoundTrip(array $elements): void
    {
        $result = $this->connection->read('SELECT $1::text[]', [PgValue::textArrayParam($elements)]);

        self::assertSame($elements, PgValue::textArray((string) pg_fetch_result($result, 0, 0)));
    }
}
