<?php

declare(strict_types=1);

namespace App\Module\Tag\Interface\Http\Response;

/**
 * {"tags": ["name", ...]}
 */
final readonly class TagsResponse
{
    /**
     * @param list<string> $tags
     */
    public function __construct(
        public array $tags,
    ) {
    }
}
