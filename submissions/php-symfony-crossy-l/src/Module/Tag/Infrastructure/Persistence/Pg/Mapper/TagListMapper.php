<?php

declare(strict_types=1);

namespace App\Module\Tag\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Tag\Domain\Model\TagList;
use App\Shared\Infrastructure\Persistence\Pg\PgValue;

final class TagListMapper
{
    /**
     * @param array<array-key, string|null> $row the column names, an array of every tag name, which is NULL when there are none
     */
    public function toDomain(array $row): TagList
    {
        return TagList::fromArray(PgValue::textArray($row['names']));
    }
}
