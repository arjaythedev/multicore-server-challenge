<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Controller;

use App\Module\Article\Application\Command\CreateArticle\CreateArticleCommandHandler;
use App\Module\Article\Interface\Http\Mapper\ArticleEnvelopeResponseMapper;
use App\Module\Article\Interface\Http\Mapper\CreateArticleRequestMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class CreateArticleAction
{
    public function __construct(
        private readonly CreateArticleRequestMapper $requestMapper,
        private readonly CreateArticleCommandHandler $handler,
        private readonly ArticleEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles', name: 'article_create', methods: ['POST'])]
    public function __invoke(Request $request, CallerContext $caller): Response
    {
        $result = $this->handler->handle($this->requestMapper->toCommand($request, $caller));

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_CREATED);
    }
}
