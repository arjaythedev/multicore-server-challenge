<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Model;

enum ArticleFilterKind
{
    case None;
    case Tag;
    case Author;
    case FavoritedBy;
}
