<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Domain\Model;

use App\Shared\Domain\Model\Moment;
use DateTimeImmutable;
use DateTimeZone;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use UnexpectedValueException;

final class MomentTest extends TestCase
{
    /**
     * @return iterable<string, array{string, string}>
     */
    public static function timestamps(): iterable
    {
        yield 'whole seconds' => ['2025-04-01 12:00:00+00', '2025-04-01T12:00:00.000Z'];
        yield 'microseconds are cut, not rounded' => ['2025-04-01 12:00:00.999999+00', '2025-04-01T12:00:00.999Z'];
        yield 'a fraction of one digit is padded' => ['2025-04-01 12:00:00.1+00', '2025-04-01T12:00:00.100Z'];
        yield 'a fraction of two digits is padded' => ['2025-04-01 12:00:00.12+00', '2025-04-01T12:00:00.120Z'];
        yield 'a fraction of three digits' => ['2025-04-01 12:00:00.123+00', '2025-04-01T12:00:00.123Z'];
        yield 'a fraction of six digits' => ['2025-04-01 12:00:00.123456+00', '2025-04-01T12:00:00.123Z'];
        yield 'a fraction with a zero in front' => ['2025-04-01 12:00:00.005+00', '2025-04-01T12:00:00.005Z'];
        yield 'midnight' => ['2025-04-01 00:00:00+00', '2025-04-01T00:00:00.000Z'];
        yield 'the last second of a year' => ['2025-12-31 23:59:59.999999+00', '2025-12-31T23:59:59.999Z'];
        yield 'a leap day' => ['2024-02-29 08:15:30.25+00', '2024-02-29T08:15:30.250Z'];
    }

    #[DataProvider('timestamps')]
    public function testIsShownInUtcWithExactlyThreeDigitsOfFraction(string $text, string $expected): void
    {
        self::assertSame($expected, Moment::fromUtcText($text)->toIso8601());
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function notUtcText(): iterable
    {
        yield 'another offset' => ['2025-04-01 00:30:00+02'];
        yield 'an offset with minutes' => ['2025-04-01 12:00:00+00:30'];
        yield 'no offset' => ['2025-04-01 12:00:00'];
        yield 'an ISO form with a T' => ['2025-04-01T12:00:00+00'];
        yield 'an ISO form ending in Z' => ['2025-04-01T12:00:00.000Z'];
        yield 'a date only' => ['2025-04-01'];
        yield 'nothing' => [''];
        yield 'words' => ['yesterday at noon'];
        yield 'a comma where the fraction starts' => ['2025-04-01 12:00:00,5+00'];
    }

    #[DataProvider('notUtcText')]
    public function testRefusesTextThatIsNotATimeInUtcWrittenThatWay(string $text): void
    {
        $this->expectException(UnexpectedValueException::class);

        Moment::fromUtcText($text);
    }

    public function testShowsTheSameAsADateObjectFormattedTheWayTheApiAlwaysHas(): void
    {
        mt_srand(5);
        $utc = new DateTimeZone('UTC');

        for ($round = 0; $round < 2000; ++$round) {
            $seconds = mt_rand(0, 4_102_444_800);
            $digits = mt_rand(0, 6);
            $fraction = $digits === 0 ? '' : '.' . substr(str_pad((string) mt_rand(0, 999_999), 6, '0', STR_PAD_LEFT), 0, $digits);
            // Postgres leaves trailing zeros off, so a fraction never ends in one.
            $fraction = rtrim($fraction, '0') === '.' ? '' : rtrim($fraction, '0');
            $text = gmdate('Y-m-d H:i:s', $seconds) . $fraction . '+00';

            self::assertSame(
                (new DateTimeImmutable($text))->setTimezone($utc)->format('Y-m-d\TH:i:s.v\Z'),
                Moment::fromUtcText($text)->toIso8601(),
                $text,
            );
        }
    }

    public function testTwoMomentsMadeFromTheSameTextAreEqual(): void
    {
        self::assertEquals(Moment::fromUtcText('2025-04-01 12:00:00.5+00'), Moment::fromUtcText('2025-04-01 12:00:00.500+00'));
    }
}
