<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Model;

/**
 * An article about to be written. Its slug comes from the title and the id it is given.
 */
readonly class NewArticle
{
    /**
     * @param list<string> $tagList tag names, repeats allowed; the ones that do not exist yet are created
     */
    public function __construct(
        public int $authorId,
        public string $title,
        public string $description,
        public string $body,
        public array $tagList,
    ) {
    }
}
