<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Result;

final readonly class CommentsResult
{
    public function __construct(
        public CommentResultList $comments,
    ) {
    }
}
