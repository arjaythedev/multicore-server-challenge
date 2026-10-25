<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\View;

use App\Shared\Domain\Model\Collection\AbstractList;

/**
 * A page of articles, newest first.
 *
 * @extends AbstractList<ArticleSummaryView>
 */
readonly class ArticleSummaryViewList extends AbstractList
{
}
