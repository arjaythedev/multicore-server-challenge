<?php

declare(strict_types=1);

namespace App\Module\Comment\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Comment\Domain\View\CommentView;
use App\Module\Comment\Domain\View\CommentViewList;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgValue;

final class CommentViewMapper
{
    public function __construct(
        private readonly ProfileViewMapper $profileViewMapper,
    ) {
    }

    /**
     * @param array<array-key, string|null> $row
     */
    public function toView(array $row): CommentView
    {
        return new CommentView(
            id: (int) $row['id'],
            body: (string) $row['body'],
            createdAt: PgValue::moment($row['created_at']),
            updatedAt: PgValue::moment($row['updated_at']),
            author: $this->profileViewMapper->toView($row),
        );
    }

    /**
     * An article without comments is one row whose comment columns are all NULL, which is no comment.
     *
     * @param list<array<array-key, string|null>> $rows
     */
    public function toViewList(array $rows): CommentViewList
    {
        $comments = [];

        foreach ($rows as $row) {
            if ($row['id'] !== null) {
                $comments[] = $this->toView($row);
            }
        }

        return CommentViewList::fromArray($comments);
    }
}
