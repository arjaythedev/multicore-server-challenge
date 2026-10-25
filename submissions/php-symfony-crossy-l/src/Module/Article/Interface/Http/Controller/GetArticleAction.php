<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Controller;

use App\Module\Article\Application\Query\GetArticle\GetArticleQuery;
use App\Module\Article\Application\Query\GetArticle\GetArticleQueryHandler;
use App\Module\Article\Interface\Http\Mapper\ArticleEnvelopeResponseMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class GetArticleAction
{
    public function __construct(
        private readonly GetArticleQueryHandler $handler,
        private readonly ArticleEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles/{slug}', name: 'article_get', methods: ['GET'])]
    public function __invoke(CallerContext $caller, string $slug): Response
    {
        $result = $this->handler->handle(new GetArticleQuery(caller: $caller, slug: $slug));

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_OK);
    }
}
