<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Mapper;

use App\Module\Comment\Application\Result\CommentsResult;
use App\Module\Comment\Interface\Http\Response\CommentsResponse;

final class CommentsResponseMapper
{
    public function __construct(
        private readonly CommentResponseMapper $commentResponseMapper,
    ) {
    }

    public function toResponse(CommentsResult $result): CommentsResponse
    {
        return new CommentsResponse(comments: $this->commentResponseMapper->toResponseList($result->comments));
    }
}
