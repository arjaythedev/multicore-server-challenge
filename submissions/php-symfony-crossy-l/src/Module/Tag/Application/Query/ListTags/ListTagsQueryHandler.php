<?php

declare(strict_types=1);

namespace App\Module\Tag\Application\Query\ListTags;

use App\Module\Tag\Application\Port\TagReadServiceInterface;
use App\Module\Tag\Application\Result\TagsResult;
use App\Shared\Application\Policy\NoAuthRequired;

#[NoAuthRequired(reason: 'The tag list is public, and the server\'s health check.')]
final class ListTagsQueryHandler
{
    public function __construct(
        private readonly TagReadServiceInterface $readService,
    ) {
    }

    /**
     * The query has no fields; it is the handler's input by convention.
     *
     * @SuppressWarnings("PHPMD.UnusedFormalParameter")
     */
    public function handle(ListTagsQuery $query): TagsResult
    {
        return $this->readService->listTags();
    }
}
