<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Controller;

use App\Module\Comment\Application\Command\DeleteComment\DeleteCommentCommandHandler;
use App\Module\Comment\Interface\Http\Mapper\DeleteCommentRequestMapper;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class DeleteCommentAction
{
    public function __construct(
        private readonly DeleteCommentRequestMapper $requestMapper,
        private readonly DeleteCommentCommandHandler $handler,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/articles/{slug}/comments/{id}', name: 'comment_delete', requirements: ['id' => '\d+'], methods: ['DELETE'])]
    public function __invoke(CallerContext $caller, string $slug, string $id): Response
    {
        $this->handler->handle($this->requestMapper->toCommand($caller, $slug, $id));

        return $this->json->noContent();
    }
}
