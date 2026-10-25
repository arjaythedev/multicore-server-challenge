<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model;

use UnexpectedValueException;

/**
 * A moment in UTC, to the millisecond: when something was created or last changed.
 *
 * Made from Postgres's text for a timestamptz in a UTC session, and shown the way the API shows it.
 */
final readonly class Moment
{
    private function __construct(
        private string $iso,
    ) {
    }

    /**
     * @param string $text 'YYYY-MM-DD HH:MM:SS', then a fraction of a second of up to six digits, or none, and '+00'
     *
     * @throws UnexpectedValueException when the text is not a time in UTC written that way
     */
    public static function fromUtcText(string $text): self
    {
        $length = \strlen($text);

        if (!self::isUtcText($text, $length)) {
            throw new UnexpectedValueException(\sprintf('"%s" is not a time in UTC.', $text));
        }

        // Postgres leaves trailing zeros off the fraction, and the API shows three digits of it, cut and not rounded.
        $milliseconds = $length === 22 ? '000' : substr(substr($text, 20, $length - 23) . '00', 0, 3);

        return new self(substr($text, 0, 10) . 'T' . substr($text, 11, 8) . '.' . $milliseconds . 'Z');
    }

    /**
     * Whether the separators are where they are in 'YYYY-MM-DD HH:MM:SS', the offset is +00, and a fraction, if there is
     * one, starts with a point.
     */
    private static function isUtcText(string $text, int $length): bool
    {
        return $length >= 22
            && $text[4] . $text[7] . $text[10] . $text[13] . $text[16] === '-- ::'
            && substr($text, -3) === '+00'
            && ($length === 22 || $text[19] === '.');
    }

    /**
     * As the API shows it: 2025-04-01T12:00:00.000Z.
     */
    public function toIso8601(): string
    {
        return $this->iso;
    }
}
