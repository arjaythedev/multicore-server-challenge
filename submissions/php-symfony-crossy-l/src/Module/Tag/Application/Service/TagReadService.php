<?php

declare(strict_types=1);

namespace App\Module\Tag\Application\Service;

use App\Module\Tag\Application\Port\TagReadServiceInterface;
use App\Module\Tag\Application\Result\TagsResult;
use App\Module\Tag\Application\UseCase\ListTags;

class TagReadService implements TagReadServiceInterface
{
    public function __construct(
        private readonly ListTags $listTags,
    ) {
    }

    public function listTags(): TagsResult
    {
        return ($this->listTags)();
    }
}
