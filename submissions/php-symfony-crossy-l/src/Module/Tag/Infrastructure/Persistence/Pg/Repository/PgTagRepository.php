<?php

declare(strict_types=1);

namespace App\Module\Tag\Infrastructure\Persistence\Pg\Repository;

use App\Module\Tag\Domain\Model\TagList;
use App\Module\Tag\Domain\Repository\TagRepositoryInterface;
use App\Module\Tag\Infrastructure\Persistence\Pg\Mapper\TagListMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;

final class PgTagRepository implements TagRepositoryInterface
{
    /** One row with every name as an array, NULL when there are no tags. */
    private const string ALL_BY_NAME = 'SELECT array_agg(name ORDER BY name) AS names FROM tags';

    public function __construct(
        private readonly PgConnection $connection,
        private readonly TagListMapper $listMapper,
    ) {
    }

    public function findAllOrderedByName(): TagList
    {
        $row = pg_fetch_assoc($this->connection->read(self::ALL_BY_NAME, []));
        \assert($row !== false);

        return $this->listMapper->toDomain($row);
    }
}
