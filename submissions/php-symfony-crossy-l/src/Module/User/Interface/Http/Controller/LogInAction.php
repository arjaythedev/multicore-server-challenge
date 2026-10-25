<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Controller;

use App\Module\User\Application\Query\LogIn\LogInQueryHandler;
use App\Module\User\Interface\Http\Mapper\LogInRequestMapper;
use App\Module\User\Interface\Http\Mapper\UserEnvelopeResponseMapper;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class LogInAction
{
    public function __construct(
        private readonly LogInRequestMapper $requestMapper,
        private readonly LogInQueryHandler $handler,
        private readonly UserEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/users/login', name: 'users_login', methods: ['POST'])]
    public function __invoke(Request $request): Response
    {
        $result = $this->handler->handle($this->requestMapper->toQuery($request));

        return $this->json->respond(
            $this->responseMapper->toResponse($result->user, $result->token),
            Response::HTTP_OK,
        );
    }
}
