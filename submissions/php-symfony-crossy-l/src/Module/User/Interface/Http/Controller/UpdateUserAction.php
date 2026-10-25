<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Controller;

use App\Module\User\Application\Command\UpdateUser\UpdateUserCommandHandler;
use App\Module\User\Interface\Http\Mapper\UpdateUserRequestMapper;
use App\Module\User\Interface\Http\Mapper\UserEnvelopeResponseMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class UpdateUserAction
{
    public function __construct(
        private readonly UpdateUserRequestMapper $requestMapper,
        private readonly UpdateUserCommandHandler $handler,
        private readonly UserEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    /**
     * The user comes back with the token the request presented.
     */
    #[Route('/api/user', name: 'user_update', methods: ['PUT'])]
    public function __invoke(Request $request, CallerContext $caller): Response
    {
        $result = $this->handler->handle($this->requestMapper->toCommand($request, $caller));

        return $this->json->respond(
            $this->responseMapper->toResponse($result, $caller->getPresentedToken()),
            Response::HTTP_OK,
        );
    }
}
