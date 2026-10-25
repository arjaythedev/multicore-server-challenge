<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Command\DeleteComment;

use App\Shared\Domain\Security\CallerContext;

final readonly class DeleteCommentCommand
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
        public int $commentId,
    ) {
    }
}
