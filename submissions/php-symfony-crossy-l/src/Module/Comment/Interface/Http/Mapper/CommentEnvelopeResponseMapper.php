<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Mapper;

use App\Module\Comment\Application\Result\CommentResult;
use App\Module\Comment\Interface\Http\Response\CommentEnvelopeResponse;

final class CommentEnvelopeResponseMapper
{
    public function __construct(
        private readonly CommentResponseMapper $commentResponseMapper,
    ) {
    }

    public function toResponse(CommentResult $comment): CommentEnvelopeResponse
    {
        return new CommentEnvelopeResponse(comment: $this->commentResponseMapper->toResponse($comment));
    }
}
