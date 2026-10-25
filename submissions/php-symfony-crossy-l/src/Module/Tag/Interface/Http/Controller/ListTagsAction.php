<?php

declare(strict_types=1);

namespace App\Module\Tag\Interface\Http\Controller;

use App\Module\Tag\Application\Query\ListTags\ListTagsQuery;
use App\Module\Tag\Application\Query\ListTags\ListTagsQueryHandler;
use App\Module\Tag\Interface\Http\Mapper\TagsResponseMapper;
use App\Shared\Interface\Http\JsonResponder;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

#[AsController]
final class ListTagsAction
{
    public function __construct(
        private readonly ListTagsQueryHandler $handler,
        private readonly TagsResponseMapper $responseMapper,
        private readonly JsonResponder $json,
    ) {
    }

    #[Route('/api/tags', name: 'tags_list', methods: ['GET'])]
    public function __invoke(): Response
    {
        $result = $this->handler->handle(new ListTagsQuery());

        return $this->json->respond($this->responseMapper->toResponse($result), Response::HTTP_OK);
    }
}
