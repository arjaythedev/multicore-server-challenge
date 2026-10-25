<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Domain\Model\Collection;

use App\Tests\Unit\Shared\Domain\Model\Collection\Fixture\IntList;
use App\Tests\Unit\Shared\Domain\Model\Collection\Fixture\WordSet;
use OutOfRangeException;
use PHPUnit\Framework\TestCase;

final class AbstractListTest extends TestCase
{
    public function testKeepsOrderAndRepeats(): void
    {
        $list = IntList::fromArray([3, 1, 3, 2]);

        self::assertSame([3, 1, 3, 2], $list->toArray());
        self::assertCount(4, $list);
    }

    public function testIsReindexedWhateverItsKeys(): void
    {
        self::assertSame([7, 8], IntList::fromArray([5 => 7, 2 => 8])->toArray());
    }

    public function testAtReadsByPositionAndNamesAnIndexThatIsNotThere(): void
    {
        $list = IntList::fromArray([10, 20]);

        self::assertSame(20, $list->at(1));

        $this->expectException(OutOfRangeException::class);
        $this->expectExceptionMessage('No item at index 2; ' . IntList::class . ' holds 2.');
        $list->at(2);
    }

    public function testEmptyAndIsEmpty(): void
    {
        self::assertTrue(IntList::empty()->isEmpty());
        self::assertFalse(IntList::fromArray([0])->isEmpty());
    }

    public function testFilterReturnsAListInTheSameOrder(): void
    {
        $evens = IntList::fromArray([4, 1, 2, 3, 6])->filter(static fn (int $n): bool => $n % 2 === 0);

        self::assertInstanceOf(IntList::class, $evens);
        self::assertSame([4, 2, 6], $evens->toArray());
    }

    public function testMapReturnsAPlainList(): void
    {
        self::assertSame(['1', '2'], IntList::fromArray([1, 2])->map(static fn (int $n): string => (string) $n));
    }

    public function testAddReturnsANewListAndLeavesTheOriginal(): void
    {
        $original = IntList::fromArray([1]);
        $longer = $original->add(2)->addList(IntList::fromArray([3, 3]));

        self::assertSame([1], $original->toArray());
        self::assertSame([1, 2, 3, 3], $longer->toArray());
    }

    public function testIsIterable(): void
    {
        $seen = [];
        foreach (IntList::fromArray([5, 6]) as $n) {
            $seen[] = $n;
        }

        self::assertSame([5, 6], $seen);
    }

    public function testBuiltFromASetInTheSetsOrder(): void
    {
        $words = WordSet::fromArray(['b', 'a', 'b']);

        self::assertSame(['b', 'a'], $words->toArray());
    }
}
