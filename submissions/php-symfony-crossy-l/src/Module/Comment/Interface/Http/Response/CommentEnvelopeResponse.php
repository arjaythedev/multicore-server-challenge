<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Response;

/**
 * {"comment": Comment}
 */
final readonly class CommentEnvelopeResponse
{
    public function __construct(
        public CommentResponse $comment,
    ) {
    }
}
