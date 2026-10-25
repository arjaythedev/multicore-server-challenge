<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Mapper;

use App\Module\Comment\Application\Result\CommentResult;
use App\Module\Comment\Application\Result\CommentResultList;
use App\Module\Comment\Interface\Http\Response\CommentResponse;
use App\Shared\Interface\Http\Mapper\ProfileResponseMapper;

final class CommentResponseMapper
{
    public function __construct(
        private readonly ProfileResponseMapper $profileResponseMapper,
    ) {
    }

    public function toResponse(CommentResult $comment): CommentResponse
    {
        return new CommentResponse(
            id: $comment->id,
            createdAt: $comment->createdAt->toIso8601(),
            updatedAt: $comment->updatedAt->toIso8601(),
            body: $comment->body,
            author: $this->profileResponseMapper->toResponse($comment->author),
        );
    }

    /**
     * @return list<CommentResponse>
     */
    public function toResponseList(CommentResultList $comments): array
    {
        return $comments->map($this->toResponse(...));
    }
}
