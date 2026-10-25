<?php

declare(strict_types=1);

namespace App\Module\Profile\Domain\Model;

use App\Shared\Domain\View\ProfileView;

/**
 * A user as their profile shows them to everyone. Who is looking adds whether they follow.
 */
readonly class ProfileUser
{
    public function __construct(
        public int $id,
        public string $username,
        public ?string $bio,
        public ?string $image,
    ) {
    }

    public function viewedBy(bool $viewerFollows): ProfileView
    {
        return new ProfileView($this->username, $this->bio, $this->image, $viewerFollows);
    }
}
