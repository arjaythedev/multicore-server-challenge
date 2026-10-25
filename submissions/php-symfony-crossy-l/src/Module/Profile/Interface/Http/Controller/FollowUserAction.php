<?php

declare(strict_types=1);

namespace App\Module\Profile\Interface\Http\Controller;

use App\Module\Profile\Application\Command\FollowUser\FollowUserCommand;
use App\Module\Profile\Application\Command\FollowUser\FollowUserCommandHandler;
use App\Module\Profile\Interface\Http\Mapper\ProfileEnvelopeResponseMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class FollowUserAction
{
    public function __construct(
        private readonly FollowUserCommandHandler $handler,
        private readonly ProfileEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/profiles/{username}/follow', name: 'profile_follow', methods: ['POST'])]
    public function __invoke(CallerContext $caller, string $username): Response
    {
        $result = $this->handler->handle(new FollowUserCommand(caller: $caller, username: $username));

        return $this->json->respond(
            $this->responseMapper->toResponse($result),
            Response::HTTP_OK,
        );
    }
}
