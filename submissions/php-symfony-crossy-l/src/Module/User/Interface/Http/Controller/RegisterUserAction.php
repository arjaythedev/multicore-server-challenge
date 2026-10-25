<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Controller;

use App\Module\User\Application\Command\RegisterUser\RegisterUserCommandHandler;
use App\Module\User\Interface\Http\Mapper\RegisterUserRequestMapper;
use App\Module\User\Interface\Http\Mapper\UserEnvelopeResponseMapper;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class RegisterUserAction
{
    public function __construct(
        private readonly RegisterUserRequestMapper $requestMapper,
        private readonly RegisterUserCommandHandler $handler,
        private readonly UserEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/users', name: 'users_register', methods: ['POST'])]
    public function __invoke(Request $request): Response
    {
        $result = $this->handler->handle($this->requestMapper->toCommand($request));

        return $this->json->respond(
            $this->responseMapper->toResponse($result->user, $result->token),
            Response::HTTP_CREATED,
        );
    }
}
