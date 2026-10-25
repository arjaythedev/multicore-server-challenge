<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Model;

/**
 * What an edit writes over an article. A null field is left as it is; a new title also gives the
 * article a new slug.
 */
readonly class ArticleChanges
{
    public function __construct(
        public ?string $title,
        public ?string $description,
        public ?string $body,
    ) {
    }
}
