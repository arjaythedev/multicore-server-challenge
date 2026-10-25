<?php

declare(strict_types=1);

namespace App\Module\Tag\Application\Port;

use App\Module\Tag\Application\Result\TagsResult;

interface TagReadServiceInterface
{
    /**
     * Every tag, sorted by name.
     */
    public function listTags(): TagsResult;
}
