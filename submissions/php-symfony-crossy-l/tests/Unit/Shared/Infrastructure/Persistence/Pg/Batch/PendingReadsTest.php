<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Persistence\Pg\Batch;

use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\Batch\PendingRead;
use App\Shared\Infrastructure\Persistence\Pg\Batch\PendingReads;
use PHPUnit\Framework\Attributes\RequiresPhpExtension;
use PHPUnit\Framework\TestCase;
use Swoole\Coroutine\Channel;

#[RequiresPhpExtension('swoole')]
final class PendingReadsTest extends TestCase
{
    public function testItStartsEmptyAndIsEmptyAgainWhenEveryReadIsTaken(): void
    {
        $pending = new PendingReads();
        self::assertTrue($pending->isEmpty());

        $pending->add(self::batched(self::read('a'), 1));
        self::assertFalse($pending->isEmpty());

        $pending->takeOldest();
        self::assertTrue($pending->isEmpty());
    }

    public function testAllTheReadsOfABatchedStatementAreTakenTogether(): void
    {
        $pending = new PendingReads();
        $read = self::read('a');

        foreach ([1, 2, 3] as $number) {
            $pending->add(self::batched($read, $number));
        }

        self::assertSame([1, 2, 3], self::numbers($pending->takeOldest()));
    }

    public function testNoMoreThanTheMostOneStatementServesAreTaken(): void
    {
        $pending = new PendingReads();
        $read = self::read('a');

        for ($number = 1; $number <= BatchedRead::MAX + 5; ++$number) {
            $pending->add(self::batched($read, $number));
        }

        self::assertCount(BatchedRead::MAX, $pending->takeOldest());
        self::assertSame(range(BatchedRead::MAX + 1, BatchedRead::MAX + 5), self::numbers($pending->takeOldest()));
    }

    public function testReadsThatCannotBeBatchedAreTakenOneAtATime(): void
    {
        $pending = new PendingReads();

        foreach ([1, 2, 3] as $number) {
            $pending->add(new PendingRead('SELECT 1', null, [$number], new Channel(1)));
        }

        self::assertSame([1], self::numbers($pending->takeOldest()));
        self::assertSame([2], self::numbers($pending->takeOldest()));
        self::assertSame([3], self::numbers($pending->takeOldest()));
        self::assertTrue($pending->isEmpty());
    }

    public function testTheReadThatHasWaitedLongestGoesFirstWhateverItsStatement(): void
    {
        $pending = new PendingReads();
        $batched = self::read('a');

        $pending->add(new PendingRead('SELECT 1', null, [1], new Channel(1)));
        $pending->add(self::batched($batched, 2));
        $pending->add(new PendingRead('SELECT 1', null, [3], new Channel(1)));
        $pending->add(self::batched($batched, 4));

        self::assertSame([1], self::numbers($pending->takeOldest()));
        self::assertSame([2, 4], self::numbers($pending->takeOldest()), 'The later read of the same statement goes with it.');
        self::assertSame([3], self::numbers($pending->takeOldest()));
        self::assertTrue($pending->isEmpty());
    }

    public function testWhatIsLeftOfAFullBatchKeepsItsPlaceInTheQueue(): void
    {
        $pending = new PendingReads();
        $first = self::read('a');
        $second = self::read('b');

        for ($number = 1; $number <= BatchedRead::MAX + 1; ++$number) {
            $pending->add(self::batched($first, $number));
        }

        $pending->add(self::batched($second, 100));

        self::assertCount(BatchedRead::MAX, $pending->takeOldest());
        self::assertSame([BatchedRead::MAX + 1], self::numbers($pending->takeOldest()), 'It arrived before the other statement\'s read.');
        self::assertSame([100], self::numbers($pending->takeOldest()));
    }

    private static function read(string $name): BatchedRead
    {
        return new BatchedRead("SELECT \$1 AS $name", ['int']);
    }

    private static function batched(BatchedRead $read, int $number): PendingRead
    {
        return new PendingRead($read->sql, $read, [$number], new Channel(1));
    }

    /**
     * @param list<PendingRead> $reads
     *
     * @return list<int>
     */
    private static function numbers(array $reads): array
    {
        return array_map(static fn (PendingRead $read): int => (int) $read->params[0], $reads);
    }
}
