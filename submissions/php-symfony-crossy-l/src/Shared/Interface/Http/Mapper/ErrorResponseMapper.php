<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http\Mapper;

use App\Shared\Interface\Http\Response\ErrorResponse;

final class ErrorResponseMapper
{
    /**
     * @param list<string> $messages
     */
    public function toResponse(array $messages): ErrorResponse
    {
        return new ErrorResponse($messages);
    }
}
