<?php

declare(strict_types=1);

namespace App\Module\Tag\Application\Result;

final readonly class TagsResult
{
    /**
     * @param list<string> $tags the names of the tags
     */
    public function __construct(
        public array $tags,
    ) {
    }
}
