<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Request;

use App\Shared\Domain\Model\Exception\ValidationException;
use Symfony\Component\HttpFoundation\Request;

/**
 * The page a list request asks for: ?limit= (1 to 100, 20 when absent) and ?offset= (0 or more, 0 when
 * absent). A parameter that is present, even empty, has to be decimal digits only, leading zeros allowed,
 * that fit in a 64-bit integer; anything else is a 422.
 */
final readonly class PageParameters
{
    private const int DEFAULT_LIMIT = 20;

    private const int MAX_LIMIT = 100;

    private function __construct(
        public int $limit,
        public int $offset,
    ) {
    }

    /**
     * @throws ValidationException
     */
    public static function fromRequest(Request $request): self
    {
        $parameters = $request->query->all();

        $limit = self::integer($parameters, 'limit') ?? self::DEFAULT_LIMIT;
        $offset = self::integer($parameters, 'offset') ?? 0;

        if ($limit < 1 || $limit > self::MAX_LIMIT) {
            throw ValidationException::withMessage('limit must be an integer from 1 to 100');
        }

        return new self($limit, $offset);
    }

    /**
     * @param array<array-key, mixed> $parameters
     */
    private static function integer(array $parameters, string $name): ?int
    {
        if (!\array_key_exists($name, $parameters)) {
            return null;
        }

        $digits = $parameters[$name];

        if (!\is_string($digits) || !ctype_digit($digits)) {
            throw ValidationException::withMessage($name . ' must be a non-negative integer');
        }

        // A number too large for an int comes back from the cast as PHP_INT_MAX, which no longer reads
        // as the digits it came from.
        $number = (int) $digits;

        if ((string) $number !== (ltrim($digits, '0') ?: '0')) {
            throw ValidationException::withMessage($name . ' is too large');
        }

        return $number;
    }
}
