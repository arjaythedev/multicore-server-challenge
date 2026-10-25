<?php

declare(strict_types=1);

namespace App\Module\Tag\Application\UseCase;

use App\Module\Tag\Application\Mapper\TagsResultMapper;
use App\Module\Tag\Application\Result\TagsResult;
use App\Module\Tag\Domain\Repository\TagRepositoryInterface;

class ListTags
{
    public function __construct(
        private readonly TagRepositoryInterface $tagRepository,
        private readonly TagsResultMapper $tagsResultMapper,
    ) {
    }

    public function __invoke(): TagsResult
    {
        return $this->tagsResultMapper->toResult($this->tagRepository->findAllOrderedByName());
    }
}
