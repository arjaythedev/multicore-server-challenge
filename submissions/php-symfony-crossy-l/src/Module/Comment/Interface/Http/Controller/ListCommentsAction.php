<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Controller;

use App\Module\Comment\Application\Query\ListComments\ListCommentsQuery;
use App\Module\Comment\Application\Query\ListComments\ListCommentsQueryHandler;
use App\Module\Comment\Interface\Http\Mapper\CommentsResponseMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class ListCommentsAction
{
    public function __construct(
        private readonly ListCommentsQueryHandler $handler,
        private readonly CommentsResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles/{slug}/comments', name: 'comments_list', methods: ['GET'])]
    public function __invoke(CallerContext $caller, string $slug): Response
    {
        $result = $this->handler->handle(new ListCommentsQuery(caller: $caller, slug: $slug));

        return $this->json->respond(
            $this->responseMapper->toResponse($result),
            Response::HTTP_OK,
        );
    }
}
