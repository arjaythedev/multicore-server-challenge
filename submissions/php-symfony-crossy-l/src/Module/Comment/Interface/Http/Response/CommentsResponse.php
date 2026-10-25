<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Response;

/**
 * {"comments": [Comment]}
 */
final readonly class CommentsResponse
{
    /**
     * @param list<CommentResponse> $comments
     */
    public function __construct(
        public array $comments,
    ) {
    }
}
