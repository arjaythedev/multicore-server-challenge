<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Controller;

use App\Module\Comment\Application\Command\AddComment\AddCommentCommandHandler;
use App\Module\Comment\Interface\Http\Mapper\AddCommentRequestMapper;
use App\Module\Comment\Interface\Http\Mapper\CommentEnvelopeResponseMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class AddCommentAction
{
    public function __construct(
        private readonly AddCommentRequestMapper $requestMapper,
        private readonly AddCommentCommandHandler $handler,
        private readonly CommentEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles/{slug}/comments', name: 'comment_add', methods: ['POST'])]
    public function __invoke(Request $request, CallerContext $caller, string $slug): Response
    {
        $result = $this->handler->handle($this->requestMapper->toCommand($request, $caller, $slug));

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_CREATED);
    }
}
