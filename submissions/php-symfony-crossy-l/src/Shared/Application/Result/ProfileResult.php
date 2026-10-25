<?php

declare(strict_types=1);

namespace App\Shared\Application\Result;

/**
 * A user as other people see them: the name, bio and image, and whether the viewer follows them. The profile page
 * shows it, and so do an article's author and a comment's author.
 */
final readonly class ProfileResult
{
    public function __construct(
        public string $username,
        public ?string $bio,
        public ?string $image,
        public bool $following,
    ) {
    }
}
