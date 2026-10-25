<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Collection;

/**
 * An immutable ordered collection that keeps what it is given, repeats included.
 *
 * Everything a list shares with a set lives on {@see AbstractCollection}; what remains here is what
 * ordering buys: appending, and being built from a set.
 *
 * @template T
 *
 * @extends AbstractCollection<T>
 */
abstract readonly class AbstractList extends AbstractCollection
{
    /**
     * @param array<T> $items
     *
     * @return list<T>
     */
    protected function normalize(array $items): array
    {
        return array_values($items);
    }

    /**
     * A list of a set's items, in the set's iteration order.
     *
     * @param AbstractSet<T> $set
     *
     * @phpstan-return static<T>
     */
    public static function fromSet(AbstractSet $set): static
    {
        return new static($set->toArray());
    }

    /**
     * @param T $item
     *
     * @phpstan-return static<T>
     */
    public function add(mixed $item): static
    {
        $newItems = $this->toArray();
        $newItems[] = $item;

        return new static($newItems);
    }

    /**
     * @param static<T> $other
     *
     * @phpstan-return static<T>
     */
    public function addList(self $other): static
    {
        return new static([...$this->toArray(), ...$other->toArray()]);
    }
}
