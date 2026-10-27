<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\User\Infrastructure\Security;

use App\Module\User\Infrastructure\Security\BcryptPasswordHasher;
use App\Shared\Domain\Model\Exception\ValidationException;
use App\Shared\Infrastructure\Worker\TaskWorkers;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class BcryptPasswordHasherTest extends TestCase
{
    public function testHashesTheWholePasswordWithCostTenAndAFreshSalt(): void
    {
        $hasher = new BcryptPasswordHasher(new TaskWorkers());
        $password = str_repeat('a', 72);
        $hash = $hasher->hash($password);

        self::assertSame(10, password_get_info($hash)['options']['cost']);
        self::assertNotSame($hash, $hasher->hash($password));
        self::assertTrue($hasher->verify($password, $hash));
        self::assertFalse($hasher->verify('wrong', $hash));
        self::assertFalse($hasher->verify($password . 'x', $hash));
    }

    /** @return iterable<string, array{string}> */
    public static function unhashablePasswords(): iterable
    {
        yield 'too long' => [str_repeat('a', 73)];
        yield 'multibyte length is bytes' => [str_repeat('é', 37)];
        yield 'NUL' => ["pass\0word"];
    }

    #[DataProvider('unhashablePasswords')]
    public function testRejectsPasswordsBcryptCannotRepresent(string $password): void
    {
        $this->expectException(ValidationException::class);
        new BcryptPasswordHasher(new TaskWorkers())->hash($password);
    }
}
