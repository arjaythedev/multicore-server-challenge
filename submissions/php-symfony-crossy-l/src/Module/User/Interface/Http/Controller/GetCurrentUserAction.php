<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Controller;

use App\Module\User\Application\Query\GetCurrentUser\GetCurrentUserQuery;
use App\Module\User\Application\Query\GetCurrentUser\GetCurrentUserQueryHandler;
use App\Module\User\Interface\Http\Mapper\UserEnvelopeResponseMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class GetCurrentUserAction
{
    public function __construct(
        private readonly GetCurrentUserQueryHandler $handler,
        private readonly UserEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    /**
     * The user comes back with the token the request presented.
     */
    #[Route('/api/user', name: 'user_current', methods: ['GET'])]
    public function __invoke(CallerContext $caller): Response
    {
        $result = $this->handler->handle(new GetCurrentUserQuery(caller: $caller));

        return $this->json->respond(
            $this->responseMapper->toResponse($result, $caller->getPresentedToken()),
            Response::HTTP_OK,
        );
    }
}
