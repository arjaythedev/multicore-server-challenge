<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Controller;

use App\Module\Article\Application\Command\UpdateArticle\UpdateArticleCommandHandler;
use App\Module\Article\Interface\Http\Mapper\ArticleEnvelopeResponseMapper;
use App\Module\Article\Interface\Http\Mapper\UpdateArticleRequestMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class UpdateArticleAction
{
    public function __construct(
        private readonly UpdateArticleRequestMapper $requestMapper,
        private readonly UpdateArticleCommandHandler $handler,
        private readonly ArticleEnvelopeResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles/{slug}', name: 'article_update', methods: ['PUT'])]
    public function __invoke(Request $request, CallerContext $caller, string $slug): Response
    {
        $result = $this->handler->handle($this->requestMapper->toCommand($request, $caller, $slug));

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_OK);
    }
}
