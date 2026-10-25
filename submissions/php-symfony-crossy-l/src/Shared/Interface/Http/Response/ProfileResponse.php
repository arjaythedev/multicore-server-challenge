<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http\Response;

/**
 * {"username", "bio", "image", "following"}: a profile, and the author of an article or a comment.
 */
final readonly class ProfileResponse
{
    public function __construct(
        public string $username,
        public ?string $bio,
        public ?string $image,
        public bool $following,
    ) {
    }
}
