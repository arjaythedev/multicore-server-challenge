<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Response;

use App\Shared\Interface\Http\Response\ProfileResponse;

/**
 * {"id", "createdAt", "updatedAt", "body", "author": Profile}
 */
final readonly class CommentResponse
{
    public function __construct(
        public int $id,
        public string $createdAt,
        public string $updatedAt,
        public string $body,
        public ProfileResponse $author,
    ) {
    }
}
