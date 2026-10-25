<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Profile\Interface\Http\Controller;

use App\Tests\Integration\Shared\AbstractControllerTestCase;

final class GetProfileActionTest extends AbstractControllerTestCase
{
    public function testFollowIsIdempotentAndEveryReadUsesItsOwnViewer(): void
    {
        $author = $this->register('profile-author');
        $viewer = $this->register('profile-viewer');
        $path = '/api/profiles/profile-author';

        self::assertFalse($this->body($this->request('GET', $path, token: $viewer))['profile']['following']);

        foreach (['POST', 'POST', 'DELETE', 'DELETE'] as $method) {
            $response = $this->request($method, $path . '/follow', token: $viewer);
            self::assertSame(200, $response->getStatusCode());
            self::assertSame($method === 'POST', $this->body($response)['profile']['following']);
            self::assertSame($method === 'POST', $this->body($this->request('GET', $path, token: $viewer))['profile']['following']);
            self::assertFalse($this->body($this->request('GET', $path, token: $author))['profile']['following']);
            self::assertFalse($this->body($this->request('GET', $path))['profile']['following']);
        }

        self::assertSame(401, $this->request('GET', $path, token: 'broken')->getStatusCode());
        self::assertSame(401, $this->request('POST', $path . '/follow')->getStatusCode());
        self::assertSame(404, $this->request('GET', '/api/profiles/not-a-user')->getStatusCode());
    }
}
