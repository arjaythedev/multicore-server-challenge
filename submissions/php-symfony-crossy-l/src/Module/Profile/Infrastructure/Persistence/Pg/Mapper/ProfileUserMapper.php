<?php

declare(strict_types=1);

namespace App\Module\Profile\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Profile\Domain\Model\ProfileUser;

final class ProfileUserMapper
{
    /**
     * @param array<array-key, string|null> $row
     */
    public function toDomain(array $row): ProfileUser
    {
        return new ProfileUser(
            id: (int) $row['id'],
            username: (string) $row['username'],
            bio: $row['bio'],
            image: $row['image'],
        );
    }
}
