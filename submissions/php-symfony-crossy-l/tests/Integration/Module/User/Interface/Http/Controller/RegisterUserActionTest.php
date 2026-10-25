<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\User\Interface\Http\Controller;

use App\Tests\Integration\Shared\AbstractControllerTestCase;

final class RegisterUserActionTest extends AbstractControllerTestCase
{
    public function testRegistrationAndPasswordUpdatePersistBcryptCostTenAndIssueUsableTokens(): void
    {
        $token = $this->register('api-user');
        $response = $this->request('GET', '/api/user', token: $token);
        self::assertSame(200, $response->getStatusCode());
        self::assertSame($token, $this->body($response)['user']['token']);
        $originalHash = $this->passwordHash('api-user');
        self::assertSame(10, password_get_info($originalHash)['options']['cost']);
        self::assertTrue(password_verify('password', $originalHash));

        $updated = $this->request('PUT', '/api/user', ['user' => [
            'username' => 'api-renamed', 'password' => 'new-password', 'bio' => '', 'image' => 'https://example.test/image',
        ]], $token);
        self::assertSame(200, $updated->getStatusCode());
        self::assertSame('', $this->body($updated)['user']['bio']);
        $hash = $this->passwordHash('api-renamed');
        self::assertNotSame($originalHash, $hash);
        self::assertSame(10, password_get_info($hash)['options']['cost']);
        self::assertTrue(password_verify('new-password', $hash));

        $oldLogin = $this->request('POST', '/api/users/login', ['user' => ['email' => 'api-user@example.test', 'password' => 'password']]);
        self::assertSame(401, $oldLogin->getStatusCode());
        $login = $this->request('POST', '/api/users/login', ['user' => ['email' => 'api-user@example.test', 'password' => 'new-password']]);
        self::assertSame(200, $login->getStatusCode());
        $newToken = $this->body($login)['user']['token'];
        self::assertSame('api-renamed', $this->body($this->request('GET', '/api/user', token: $newToken))['user']['username']);
    }

    public function testNullFieldsLeaveTheAccountUnchangedAndTheNextRequestIsAnonymous(): void
    {
        $token = $this->register('api-null');
        $before = $this->body($this->request('GET', '/api/user', token: $token));
        $after = $this->request('PUT', '/api/user', ['user' => [
            'email' => null, 'username' => null, 'password' => null, 'bio' => null, 'image' => null,
        ]], $token);

        self::assertSame(200, $after->getStatusCode());
        self::assertSame($before, $this->body($after));
        self::assertSame(401, $this->request('GET', '/api/user')->getStatusCode());
    }

    private function passwordHash(string $username): string
    {
        return (string) pg_fetch_result($this->connection->read('SELECT password_hash FROM users WHERE username = $1', [$username]), 0, 0);
    }
}
