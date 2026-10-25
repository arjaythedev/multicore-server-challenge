<?php

declare(strict_types=1);

namespace App\Module\Tag\Application\Mapper;

use App\Module\Tag\Application\Result\TagsResult;
use App\Module\Tag\Domain\Model\TagList;

final class TagsResultMapper
{
    public function toResult(TagList $tags): TagsResult
    {
        return new TagsResult(tags: $tags->toArray());
    }
}
