<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg\Mapper;

use App\Shared\Domain\View\ProfileView;
use App\Shared\Infrastructure\Persistence\Pg\PgValue;

/**
 * A profile from the columns username, bio, image and following, which a profile row, an article row and a comment
 * row each carry for their author.
 */
final class ProfileViewMapper
{
    /**
     * @param array<array-key, string|null> $row
     */
    public function toView(array $row): ProfileView
    {
        return new ProfileView(
            username: (string) $row['username'],
            bio: $row['bio'],
            image: $row['image'],
            following: PgValue::bool($row['following']),
        );
    }
}
