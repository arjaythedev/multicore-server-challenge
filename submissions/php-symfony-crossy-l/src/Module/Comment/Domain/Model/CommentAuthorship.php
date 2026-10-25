<?php

declare(strict_types=1);

namespace App\Module\Comment\Domain\Model;

/**
 * A comment and who wrote it: what deciding whether a caller may delete it needs.
 */
readonly class CommentAuthorship
{
    public function __construct(
        public int $commentId,
        public int $authorId,
    ) {
    }
}
