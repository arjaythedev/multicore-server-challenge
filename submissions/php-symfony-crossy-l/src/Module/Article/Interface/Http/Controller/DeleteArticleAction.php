<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Controller;

use App\Module\Article\Application\Command\DeleteArticle\DeleteArticleCommand;
use App\Module\Article\Application\Command\DeleteArticle\DeleteArticleCommandHandler;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class DeleteArticleAction
{
    public function __construct(
        private readonly DeleteArticleCommandHandler $handler,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles/{slug}', name: 'article_delete', methods: ['DELETE'])]
    public function __invoke(CallerContext $caller, string $slug): Response
    {
        $this->handler->handle(new DeleteArticleCommand(caller: $caller, slug: $slug));

        return $this->json->noContent();
    }
}
