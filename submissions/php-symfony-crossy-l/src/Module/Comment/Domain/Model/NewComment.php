<?php

declare(strict_types=1);

namespace App\Module\Comment\Domain\Model;

readonly class NewComment
{
    public function __construct(
        public int $articleId,
        public int $authorId,
        public string $body,
    ) {
    }
}
