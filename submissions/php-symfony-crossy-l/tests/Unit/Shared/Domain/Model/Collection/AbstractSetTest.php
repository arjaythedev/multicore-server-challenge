<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Domain\Model\Collection;

use App\Tests\Unit\Shared\Domain\Model\Collection\Fixture\WordSet;
use PHPUnit\Framework\TestCase;

final class AbstractSetTest extends TestCase
{
    public function testHoldsEachItemOnceAndKeepsTheLastOfARepeat(): void
    {
        $set = WordSet::fromArray(['b', 'a', 'b', 'c']);

        self::assertSame(['b', 'a', 'c'], $set->toArray());
        self::assertCount(3, $set);
    }

    public function testHasAnswersByIdentity(): void
    {
        $set = WordSet::fromArray(['a']);

        self::assertTrue($set->has('a'));
        self::assertFalse($set->has('b'));
    }

    public function testAddOfAMemberChangesNothing(): void
    {
        $set = WordSet::fromArray(['a']);

        self::assertSame($set, $set->add('a'));
        self::assertSame(['a', 'b'], $set->add('b')->toArray());
        self::assertSame(['a'], $set->toArray());
    }

    public function testAddSetKeepsTheMembersAlreadyThere(): void
    {
        $union = WordSet::fromArray(['a', 'b'])->addSet(WordSet::fromArray(['b', 'c']));

        self::assertSame(['a', 'b', 'c'], $union->toArray());
    }

    public function testRemoveLeavesTheOthersInOrder(): void
    {
        $set = WordSet::fromArray(['a', 'b', 'c']);

        self::assertSame(['a', 'c'], $set->remove('b')->toArray());
        self::assertSame($set, $set->remove('z'));
    }

    public function testFilterAndMapWorkLikeAList(): void
    {
        $set = WordSet::fromArray(['a', 'bb', 'cc']);

        self::assertSame(['bb', 'cc'], $set->filter(static fn (string $w): bool => \strlen($w) === 2)->toArray());
        self::assertSame([1, 2, 2], $set->map(static fn (string $w): int => \strlen($w)));
    }
}
