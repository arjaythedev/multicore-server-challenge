<?php

declare(strict_types=1);

namespace App\Shared\Domain\View;

/**
 * A user as other people see them: the name, bio and image, and whether the viewer follows them.
 * The profile, article and comment modules each read it with their own statement.
 */
readonly class ProfileView
{
    public function __construct(
        public string $username,
        public ?string $bio,
        public ?string $image,
        public bool $following,
    ) {
    }
}
