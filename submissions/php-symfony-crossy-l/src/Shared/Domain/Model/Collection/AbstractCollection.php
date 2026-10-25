<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Collection;

use ArrayIterator;
use Countable;
use IteratorAggregate;
use OutOfRangeException;

/**
 * What a list and a set have in common: immutable, iterable, countable, positionally readable.
 *
 * Every operation that changes the contents returns a new instance.
 *
 * @template T
 *
 * @implements IteratorAggregate<int, T>
 */
abstract readonly class AbstractCollection implements IteratorAggregate, Countable
{
    /**
     * Keyed for a set, sequential for a list — read it through toArray() unless you are the subclass
     * that decided the keying.
     *
     * @var array<array-key, T>
     */
    protected array $items;

    /**
     * @param array<T> $items
     */
    final protected function __construct(array $items)
    {
        $this->items = $this->normalize($items);
    }

    /**
     * Decide how these items are held: in order, or by identity.
     *
     * @param array<T> $items
     *
     * @return array<array-key, T>
     */
    abstract protected function normalize(array $items): array;

    /**
     * @param array<T> $items
     *
     * @phpstan-return static<T>
     */
    public static function fromArray(array $items): static
    {
        return new static($items);
    }

    /**
     * @phpstan-return static<T>
     */
    public static function empty(): static
    {
        return new static([]);
    }

    /**
     * The item at a position, counting from zero. An index with nothing at it throws, naming the index
     * and the count.
     *
     * @return T
     *
     * @throws OutOfRangeException if nothing sits at that index
     */
    public function at(int $index): mixed
    {
        $items = $this->toArray();

        // array_key_exists, not isset: an item that is legitimately null is present.
        if (!\array_key_exists($index, $items)) {
            throw new OutOfRangeException(\sprintf(
                'No item at index %d; %s holds %d.',
                $index,
                static::class,
                $this->count(),
            ));
        }

        return $items[$index];
    }

    /**
     * @return list<T>
     */
    public function toArray(): array
    {
        return array_values($this->items);
    }

    public function isEmpty(): bool
    {
        return $this->items === [];
    }

    public function count(): int
    {
        return \count($this->items);
    }

    /**
     * @return ArrayIterator<int, T>
     */
    public function getIterator(): ArrayIterator
    {
        return new ArrayIterator($this->toArray());
    }

    /**
     * @param callable(T): bool $callback
     *
     * @phpstan-return static<T>
     */
    public function filter(callable $callback): static
    {
        return new static(array_values(array_filter($this->items, $callback)));
    }

    /**
     * @template U
     *
     * @param callable(T): U $callback
     *
     * @return list<U>
     */
    public function map(callable $callback): array
    {
        return array_map($callback, $this->toArray());
    }
}
