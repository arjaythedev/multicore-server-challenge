<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg\Batch;

use InvalidArgumentException;

/**
 * A read that can run for several requests in one statement. $body is one request's statement, its parameters
 * written $1, $2, ...; the batched form takes an array for each parameter and runs the body once per request as a
 * lateral subquery. Every row starts with the position of the request it belongs to.
 */
final readonly class BatchedRead
{
    /** The most requests one statement serves. */
    public const int MAX = 32;

    public string $sql;

    /**
     * @param list<string> $types the Postgres type of each parameter, in order
     */
    public function __construct(string $body, array $types)
    {
        $arrays = [];
        $columns = [];
        $names = [];

        foreach ($types as $position => $type) {
            $number = $position + 1;
            $arrays[] = '$' . $number . '::' . $type . '[]';
            $columns[] = 'p' . $number;
            $names['$' . $number] = 'q.p' . $number;
        }

        $this->sql = 'SELECT q.ord, b.* FROM unnest(' . implode(', ', $arrays) . ') WITH ORDINALITY AS q(' . implode(', ', [...$columns, 'ord']) . ')'
            . ' CROSS JOIN LATERAL (' . strtr($body, $names) . ') b';
    }

    /**
     * The batched statement's parameters: one Postgres array literal per parameter, every element quoted and cut at a
     * NUL byte as libpq cuts a parameter.
     *
     * @param list<list<float|int|string|null>> $paramsByRequest
     *
     * @return list<string>
     */
    public static function arrays(array $paramsByRequest): array
    {
        $columns = [];

        foreach ($paramsByRequest as $params) {
            foreach ($params as $position => $value) {
                $columns[$position][] = self::element((string) ($value ?? throw new InvalidArgumentException('A batched read takes no NULL.')));
            }
        }

        return array_values(array_map(static fn (array $elements): string => '{' . implode(',', $elements) . '}', $columns));
    }

    private static function element(string $text): string
    {
        $end = strpos($text, "\0");

        if ($end !== false) {
            $text = substr($text, 0, $end);
        }

        return '"' . addcslashes($text, '"\\') . '"';
    }
}
