<?php

declare(strict_types=1);

namespace App\Module\Comment\Application\Result;

use App\Shared\Application\Result\ProfileResult;
use App\Shared\Domain\Model\Moment;

final readonly class CommentResult
{
    public function __construct(
        public int $id,
        public Moment $createdAt,
        public Moment $updatedAt,
        public string $body,
        public ProfileResult $author,
    ) {
    }
}
