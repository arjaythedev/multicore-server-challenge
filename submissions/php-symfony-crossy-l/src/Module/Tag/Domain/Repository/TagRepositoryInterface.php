<?php

declare(strict_types=1);

namespace App\Module\Tag\Domain\Repository;

use App\Module\Tag\Domain\Model\TagList;

interface TagRepositoryInterface
{
    /**
     * Every tag, sorted by name.
     */
    public function findAllOrderedByName(): TagList;
}
