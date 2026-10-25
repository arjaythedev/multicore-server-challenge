<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Controller;

use App\Module\Article\Application\Query\ListArticles\ListArticlesQueryHandler;
use App\Module\Article\Interface\Http\Mapper\ArticlesResponseMapper;
use App\Module\Article\Interface\Http\Mapper\ListArticlesRequestMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class ListArticlesAction
{
    public function __construct(
        private readonly ListArticlesRequestMapper $requestMapper,
        private readonly ListArticlesQueryHandler $handler,
        private readonly ArticlesResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles', name: 'articles_list', methods: ['GET'])]
    public function __invoke(Request $request, CallerContext $caller): Response
    {
        $result = $this->handler->handle($this->requestMapper->toQuery($request, $caller));

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_OK);
    }
}
