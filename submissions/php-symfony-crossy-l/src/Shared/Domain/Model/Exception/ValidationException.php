<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Exception;

use DomainException;

/**
 * The request body or query is not acceptable. Served as HTTP 422, one message per problem.
 */
class ValidationException extends DomainException implements DomainExceptionInterface
{
    /**
     * @param list<string> $errors
     */
    public function __construct(
        string $message,
        private readonly array $errors,
    ) {
        parent::__construct($message);
    }

    public static function withMessage(string $message): self
    {
        return new self($message, [$message]);
    }

    /**
     * @param list<string> $errors
     */
    public static function withErrors(string $message, array $errors): self
    {
        return new self($message, $errors);
    }

    /**
     * @return list<string>
     */
    public function getErrors(): array
    {
        return $this->errors;
    }
}
