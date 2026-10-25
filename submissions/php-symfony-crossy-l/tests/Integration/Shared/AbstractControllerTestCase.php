<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared;

use App\Tests\Integration\Shared\Trait\RunsInRolledBackTransaction;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

abstract class AbstractControllerTestCase extends KernelTestCase
{
    use RunsInRolledBackTransaction;

    /** @param array<string, mixed> $body */
    protected function request(string $method, string $uri, array $body = [], ?string $token = null): Response
    {
        self::assertNotNull(self::$kernel);
        $server = ['CONTENT_TYPE' => 'application/json'];

        if ($token !== null) {
            $server['HTTP_AUTHORIZATION'] = 'Token ' . $token;
        }

        $request = Request::create($uri, $method, [], [], [], $server, json_encode($body, JSON_THROW_ON_ERROR));
        $response = self::$kernel->handle($request);
        self::$kernel->terminate($request, $response);

        return $response;
    }

    /** @return array<string, mixed> */
    protected function body(Response $response): array
    {
        $body = json_decode((string) $response->getContent(), true, 512, JSON_THROW_ON_ERROR);
        self::assertIsArray($body);

        return $body;
    }

    protected function register(string $username): string
    {
        $response = $this->request('POST', '/api/users', ['user' => [
            'username' => $username,
            'email' => $username . '@example.test',
            'password' => 'password',
        ]]);
        self::assertSame(201, $response->getStatusCode(), (string) $response->getContent());

        return $this->body($response)['user']['token'];
    }

    /** @param list<string> $tags */
    protected function createArticle(string $token, string $title, array $tags = []): string
    {
        $response = $this->request('POST', '/api/articles', ['article' => [
            'title' => $title,
            'description' => 'description',
            'body' => 'body',
            'tagList' => $tags,
        ]], $token);
        self::assertSame(201, $response->getStatusCode(), (string) $response->getContent());

        return $this->body($response)['article']['slug'];
    }
}
