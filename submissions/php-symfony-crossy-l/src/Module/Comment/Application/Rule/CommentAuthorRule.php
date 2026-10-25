<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Rule;

use App\Module\Comment\Domain\Model\CommentAuthorship;
use App\Shared\Domain\Model\Exception\ForbiddenException;

/**
 * Only a comment's author may delete it. Anyone may learn that the comment exists.
 */
final class CommentAuthorRule
{
    public function apply(CommentAuthorship $comment, int $userId): void
    {
        if ($comment->authorId !== $userId) {
            throw ForbiddenException::withMessage('only the author may delete this comment');
        }
    }
}
