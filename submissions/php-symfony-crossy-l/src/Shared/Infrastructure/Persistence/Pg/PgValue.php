<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg;

use App\Shared\Domain\Model\Moment;
use UnexpectedValueException;

/**
 * Converts between PHP values and the text form Postgres sends and receives them in.
 */
final class PgValue
{
    /** An element of a text[] literal: quoted, with backslash escapes, or bare. */
    private const string ARRAY_ELEMENT = '/"((?:[^"\\\\]|\\\\.)*)"|([^,{}]+)/s';

    public static function bool(?string $text): bool
    {
        return $text === 't';
    }

    /**
     * A timestamptz column. The session runs in UTC, so the text ends in +00.
     */
    public static function moment(?string $text): Moment
    {
        if ($text === null) {
            throw new UnexpectedValueException('A timestamp column was NULL.');
        }

        return Moment::fromUtcText($text);
    }

    /**
     * The elements of a text[] column with no NULL elements, in order.
     *
     * @return list<string>
     */
    public static function textArray(?string $literal): array
    {
        if ($literal === null || $literal === '{}') {
            return [];
        }

        // Postgres quotes an element that has a comma, brace, quote, backslash or space in it, or that is empty or
        // reads as NULL. Without a quote or a backslash in the literal, every element is bare, so the commas split it.
        if (!str_contains($literal, '"') && !str_contains($literal, '\\')) {
            return explode(',', substr($literal, 1, -1));
        }

        preg_match_all(self::ARRAY_ELEMENT, $literal, $matches, PREG_SET_ORDER | PREG_UNMATCHED_AS_NULL);

        $elements = [];

        foreach ($matches as [, $quoted, $bare]) {
            $elements[] = $bare ?? (string) preg_replace('/\\\\(.)/s', '$1', (string) $quoted);
        }

        return $elements;
    }

    /**
     * A text[] parameter: every element quoted, so no element is read as NULL.
     *
     * @param list<string> $elements
     */
    public static function textArrayParam(array $elements): string
    {
        $quoted = array_map(static fn (string $element): string => '"' . addcslashes($element, '"\\') . '"', $elements);

        return '{' . implode(',', $quoted) . '}';
    }
}
