<?php

declare(strict_types=1);

namespace App\Module\Comment\Domain\View;

use App\Shared\Domain\Model\Moment;
use App\Shared\Domain\View\ProfileView;

/**
 * A comment as a viewer sees it.
 */
readonly class CommentView
{
    public function __construct(
        public int $id,
        public string $body,
        public Moment $createdAt,
        public Moment $updatedAt,
        public ProfileView $author,
    ) {
    }
}
