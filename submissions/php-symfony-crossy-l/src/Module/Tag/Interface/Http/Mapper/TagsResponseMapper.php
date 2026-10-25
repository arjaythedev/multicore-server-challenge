<?php

declare(strict_types=1);

namespace App\Module\Tag\Interface\Http\Mapper;

use App\Module\Tag\Application\Result\TagsResult;
use App\Module\Tag\Interface\Http\Response\TagsResponse;

final class TagsResponseMapper
{
    public function toResponse(TagsResult $result): TagsResponse
    {
        return new TagsResponse(tags: $result->tags);
    }
}
