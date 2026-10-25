<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Infrastructure\Persistence\Pg\PgValue;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class PgValueTextArrayTest extends TestCase
{
    /**
     * @return iterable<string, array{string, list<string>}>
     */
    public static function literals(): iterable
    {
        yield 'a missing value' => ['', []];
        yield 'an empty array' => ['{}', []];
        yield 'one bare element' => ['{php}', ['php']];
        yield 'bare elements' => ['{a,b,c}', ['a', 'b', 'c']];
        yield 'bare elements with digits, hyphens and dots' => ['{react-native,web3,node.js}', ['react-native', 'web3', 'node.js']];
        yield 'a quoted element with a space' => ['{"web development",react}', ['web development', 'react']];
        yield 'a quoted comma' => ['{"a,b",c}', ['a,b', 'c']];
        yield 'an escaped quote and backslash' => ['{"say \"hi\"","back\\\\slash"}', ['say "hi"', 'back\\slash']];
        yield 'an empty string' => ['{"",a}', ['', 'a']];
        yield 'the word NULL as text' => ['{"NULL",a}', ['NULL', 'a']];
    }

    /**
     * @param list<string> $expected
     */
    #[DataProvider('literals')]
    public function testParsesALiteral(string $literal, array $expected): void
    {
        self::assertSame($expected, PgValue::textArray($literal === '' ? null : $literal));
    }

    public function testTheFastPathAgreesWithTheFullParserOnGeneratedLiterals(): void
    {
        mt_srand(11);
        $alphabet = str_split('abcdefghijklmnopqrstuvwxyz0123456789-_.+%@é');

        for ($round = 0; $round < 300; ++$round) {
            $elements = [];

            for ($count = mt_rand(1, 8); $count > 0; --$count) {
                $name = '';

                for ($length = mt_rand(1, 12); $length > 0; --$length) {
                    $name .= $alphabet[mt_rand(0, \count($alphabet) - 1)];
                }

                $elements[] = $name;
            }

            // The text Postgres writes for these has no quote, so the fast path takes it; the literal built with every
            // element quoted does not, so the full parser reads it.
            self::assertSame($elements, PgValue::textArray('{' . implode(',', $elements) . '}'));
            self::assertSame($elements, PgValue::textArray(PgValue::textArrayParam($elements)));
        }
    }
}
