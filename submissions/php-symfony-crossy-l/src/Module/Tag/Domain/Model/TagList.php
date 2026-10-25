<?php

declare(strict_types=1);

namespace App\Module\Tag\Domain\Model;

use App\Shared\Domain\Model\Collection\AbstractList;

/**
 * The names of tags, in the order the repository read them.
 *
 * @extends AbstractList<string>
 */
readonly class TagList extends AbstractList
{
}
