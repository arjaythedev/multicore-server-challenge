<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Controller;

use App\Module\Article\Application\Query\GetFeed\GetFeedQueryHandler;
use App\Module\Article\Interface\Http\Mapper\ArticlesResponseMapper;
use App\Module\Article\Interface\Http\Mapper\GetFeedRequestMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class GetFeedAction
{
    public function __construct(
        private readonly GetFeedRequestMapper $requestMapper,
        private readonly GetFeedQueryHandler $handler,
        private readonly ArticlesResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    /**
     * Matched ahead of /api/articles/{slug}, which would otherwise read "feed" as a slug.
     */
    #[Route('/api/articles/feed', name: 'articles_feed', methods: ['GET'], priority: 1)]
    public function __invoke(Request $request, CallerContext $caller): Response
    {
        $result = $this->handler->handle($this->requestMapper->toQuery($request, $caller));

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_OK);
    }
}
