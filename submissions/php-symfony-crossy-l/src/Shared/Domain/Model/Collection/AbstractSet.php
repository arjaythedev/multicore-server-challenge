<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Collection;

use Stringable;

/**
 * An immutable collection that holds each item once.
 *
 * Everything a set shares with a list lives on {@see AbstractCollection}; what remains here is what
 * identity buys: membership, removal, and the key that decides when two items are the same one.
 *
 * @template T
 *
 * @extends AbstractCollection<T>
 */
abstract readonly class AbstractSet extends AbstractCollection
{
    /**
     * A repeat replaces its twin.
     *
     * @param array<T> $items
     *
     * @return array<string, T>
     */
    protected function normalize(array $items): array
    {
        $indexed = [];

        foreach ($items as $item) {
            $indexed[$this->getItemKey($item)] = $item;
        }

        return $indexed;
    }

    /**
     * @param T $item
     */
    public function has(mixed $item): bool
    {
        return isset($this->items[$this->getItemKey($item)]);
    }

    /**
     * @param T $item
     *
     * @phpstan-return static<T>
     */
    public function add(mixed $item): static
    {
        if ($this->has($item)) {
            /** @phpstan-ignore-next-line the set already holds it, and it is immutable */
            return $this;
        }

        $newItems = $this->toArray();
        $newItems[] = $item;

        return new static($newItems);
    }

    /**
     * @param static<T> $set
     *
     * @phpstan-return static<T>
     */
    public function addSet(self $set): static
    {
        $newItems = $this->toArray();

        foreach ($set as $item) {
            if (!$this->has($item)) {
                $newItems[] = $item;
            }
        }

        return new static($newItems);
    }

    /**
     * @param T $item
     *
     * @phpstan-return static<T>
     */
    public function remove(mixed $item): static
    {
        $key = $this->getItemKey($item);

        if (!isset($this->items[$key])) {
            /** @phpstan-ignore-next-line the set does not hold it, and it is immutable */
            return $this;
        }

        return new static(array_values(array_filter(
            $this->items,
            fn ($existingItem): bool => $this->getItemKey($existingItem) !== $key,
        )));
    }

    /**
     * The key that decides when two items are the same one: the text of a Stringable, the value of a
     * scalar, the serialized form of an array, and for any other object its identity. A subclass whose
     * items are equal by something else overrides it.
     *
     * @param T $item
     */
    protected function getItemKey(mixed $item): string
    {
        return match (true) {
            $item instanceof Stringable => (string) $item,
            \is_object($item) => spl_object_hash($item),
            \is_array($item) => md5(serialize($item)),
            \is_scalar($item) => (string) $item,
            default => serialize($item),
        };
    }
}
