<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Command\AddComment;

use App\Shared\Domain\Security\CallerContext;

final readonly class AddCommentCommand
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
        public string $body,
    ) {
    }
}
