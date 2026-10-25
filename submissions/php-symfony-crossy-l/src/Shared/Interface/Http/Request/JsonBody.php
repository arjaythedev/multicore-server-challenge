<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http\Request;

use App\Shared\Domain\Model\Exception\ValidationException;
use JsonException;
use stdClass;

/**
 * The fields of a request body, which wraps them in an object under one key: {"user": {...}}.
 *
 * A body that is not JSON, not an object, or has no object under the key is refused with a 422, and so is
 * each field read with the wrong type. Field names match exactly; fields nobody reads are ignored.
 */
final readonly class JsonBody
{
    /**
     * @param array<array-key, mixed> $fields
     */
    private function __construct(
        private array $fields,
    ) {
    }

    /**
     * @throws ValidationException
     */
    public static function unwrap(string $content, string $wrapper): self
    {
        try {
            // Objects decode to stdClass and arrays to arrays, so {"user": []} is not {"user": {}}.
            $body = json_decode($content, false, 64, JSON_THROW_ON_ERROR);
        } catch (JsonException) {
            throw ValidationException::withMessage('the body must be JSON');
        }

        $fields = $body instanceof stdClass ? ($body->{$wrapper} ?? null) : null;

        if (!$fields instanceof stdClass) {
            throw ValidationException::withMessage(\sprintf('the body must be {"%s": {...}}', $wrapper));
        }

        return new self(get_object_vars($fields));
    }

    /**
     * A field that has to be there, as a string that is not empty.
     *
     * @throws ValidationException
     */
    public function requiredString(string $field): string
    {
        return $this->optionalNonEmptyString($field) ?? throw self::invalid($field, 'is required');
    }

    /**
     * A field that may be absent or null, both read as null; otherwise a string that is not empty.
     *
     * @throws ValidationException
     */
    public function optionalNonEmptyString(string $field): ?string
    {
        $value = $this->optionalString($field);

        if ($value === '') {
            throw self::invalid($field, 'must not be empty');
        }

        return $value;
    }

    /**
     * A field that may be absent or null, both read as null; otherwise a string, which may be empty.
     *
     * @throws ValidationException
     */
    public function optionalString(string $field): ?string
    {
        $value = $this->fields[$field] ?? null;

        if ($value !== null && !\is_string($value)) {
            throw self::invalid($field, 'must be a string');
        }

        return $value;
    }

    /**
     * A field that may be absent or null, both read as no strings; otherwise an array of non-empty strings.
     *
     * @return list<string>
     *
     * @throws ValidationException
     */
    public function optionalStringList(string $field): array
    {
        $value = $this->fields[$field] ?? null;

        if ($value === null) {
            return [];
        }

        if (!\is_array($value)) {
            throw self::invalid($field, 'must be an array of strings');
        }

        $strings = [];

        foreach ($value as $item) {
            if (!\is_string($item) || $item === '') {
                throw self::invalid($field, 'must hold non-empty strings only');
            }

            $strings[] = $item;
        }

        return $strings;
    }

    private static function invalid(string $field, string $problem): ValidationException
    {
        return ValidationException::withMessage($field . ' ' . $problem);
    }
}
