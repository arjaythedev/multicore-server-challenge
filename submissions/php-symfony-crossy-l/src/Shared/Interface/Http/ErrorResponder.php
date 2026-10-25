<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http;

use App\Shared\Domain\Model\Exception\ForbiddenException;
use App\Shared\Domain\Model\Exception\NotFoundException;
use App\Shared\Domain\Model\Exception\UnauthorizedException;
use App\Shared\Domain\Model\Exception\ValidationException;
use App\Shared\Interface\Http\Mapper\ErrorResponseMapper;
use Symfony\Component\HttpFoundation\Exception\RequestExceptionInterface;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Symfony\Component\Routing\Exception\MethodNotAllowedException;
use Symfony\Component\Routing\Exception\ResourceNotFoundException;
use Throwable;

/**
 * Answers every exception with the JSON error body, so that nothing a request throws escapes the worker.
 *
 * Domain exceptions carry their status. An unknown route or a known route called with another
 * method is a 404. Anything else is a 500 whose detail goes to the error log, not to the client.
 */
final class ErrorResponder
{
    public function __construct(
        private readonly ErrorResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    public function respond(Throwable $error): Response
    {
        [$status, $messages] = match (true) {
            $error instanceof ValidationException => [Response::HTTP_UNPROCESSABLE_ENTITY, $error->getErrors()],
            $error instanceof UnauthorizedException => [Response::HTTP_UNAUTHORIZED, [$error->getMessage()]],
            $error instanceof ForbiddenException => [Response::HTTP_FORBIDDEN, [$error->getMessage()]],
            $error instanceof NotFoundException => [Response::HTTP_NOT_FOUND, [$error->getMessage()]],
            $error instanceof ResourceNotFoundException,
            $error instanceof MethodNotAllowedException => [Response::HTTP_NOT_FOUND, ['not found']],
            $error instanceof RequestExceptionInterface => [Response::HTTP_BAD_REQUEST, ['request error']],
            $error instanceof HttpExceptionInterface => [$error->getStatusCode(), ['request error']],
            default => [Response::HTTP_INTERNAL_SERVER_ERROR, ['internal server error']],
        };

        if ($status === Response::HTTP_INTERNAL_SERVER_ERROR) {
            error_log((string) $error);
        }

        return $this->json->respond($this->responseMapper->toResponse($messages), $status);
    }
}
