<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http\Response;

/**
 * The body of every error: {"errors": {"body": ["<message>", ...]}}.
 */
final readonly class ErrorResponse
{
    /** @var array{body: list<string>} */
    public array $errors;

    /**
     * @param list<string> $messages
     */
    public function __construct(array $messages)
    {
        $this->errors = ['body' => $messages];
    }
}
