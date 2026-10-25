<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Mapper;

use App\Module\Comment\Application\Command\DeleteComment\DeleteCommentCommand;
use App\Shared\Domain\Model\Exception\NotFoundException;
use App\Shared\Domain\Security\CallerContext;

/**
 * An id too large for a 64-bit integer names no comment.
 */
final class DeleteCommentRequestMapper
{
    public function toCommand(CallerContext $caller, string $slug, string $id): DeleteCommentCommand
    {
        $commentId = filter_var(ltrim($id, '0') ?: '0', FILTER_VALIDATE_INT);

        if ($commentId === false) {
            throw NotFoundException::withMessage('comment not found');
        }

        return new DeleteCommentCommand(caller: $caller, slug: $slug, commentId: $commentId);
    }
}
