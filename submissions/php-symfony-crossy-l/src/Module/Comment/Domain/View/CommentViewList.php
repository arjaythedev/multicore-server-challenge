<?php

declare(strict_types=1);

namespace App\Module\Comment\Domain\View;

use App\Shared\Domain\Model\Collection\AbstractList;

/**
 * An article's comments, newest first.
 *
 * @extends AbstractList<CommentView>
 */
readonly class CommentViewList extends AbstractList
{
}
