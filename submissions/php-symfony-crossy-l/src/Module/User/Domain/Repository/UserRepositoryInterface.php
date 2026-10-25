<?php

declare(strict_types=1);

namespace App\Module\User\Domain\Repository;

use App\Module\User\Domain\Model\Exception\UsernameOrEmailTakenException;
use App\Module\User\Domain\Model\NewUser;
use App\Module\User\Domain\Model\User;
use App\Module\User\Domain\Model\UserChanges;
use App\Module\User\Domain\Model\UserCredentials;

interface UserRepositoryInterface
{
    /**
     * @throws UsernameOrEmailTakenException
     */
    public function add(NewUser $user): User;

    public function findById(int $id): ?User;

    public function findCredentialsByEmail(string $email): ?UserCredentials;

    /**
     * Writes the changes over the account, or returns null when there is no account with that id.
     *
     * @throws UsernameOrEmailTakenException
     */
    public function update(int $id, UserChanges $changes): ?User;
}
