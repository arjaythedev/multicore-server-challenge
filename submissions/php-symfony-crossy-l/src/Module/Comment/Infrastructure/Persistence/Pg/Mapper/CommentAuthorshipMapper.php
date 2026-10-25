<?php

declare(strict_types=1);

namespace App\Module\Comment\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Comment\Domain\Model\CommentAuthorship;

final class CommentAuthorshipMapper
{
    /**
     * @param array<array-key, string|null> $row the columns id and author_id of a comment
     */
    public function toDomain(array $row): CommentAuthorship
    {
        return new CommentAuthorship(commentId: (int) $row['id'], authorId: (int) $row['author_id']);
    }
}
