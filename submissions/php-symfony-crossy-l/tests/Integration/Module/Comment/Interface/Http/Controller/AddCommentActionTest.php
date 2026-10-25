<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Comment\Interface\Http\Controller;

use App\Tests\Integration\Shared\AbstractControllerTestCase;

final class AddCommentActionTest extends AbstractControllerTestCase
{
    public function testCommentsAreScopedToTheirArticleAndOnlyTheirAuthorCanDeleteThem(): void
    {
        $author = $this->register('comment-author');
        $other = $this->register('comment-other');
        $slug = $this->createArticle($author, 'With Comments');
        $otherSlug = $this->createArticle($author, 'Another Article');
        $path = '/api/articles/' . $slug . '/comments';
        $this->request('POST', '/api/profiles/comment-author/follow', token: $author);

        $first = $this->request('POST', $path, ['comment' => ['body' => 'first']], $author);
        self::assertSame(201, $first->getStatusCode());
        self::assertFalse($this->body($first)['comment']['author']['following']);
        $id = $this->body($first)['comment']['id'];
        $second = $this->request('POST', $path, ['comment' => ['body' => 'second']], $other);
        self::assertSame(201, $second->getStatusCode());
        $comments = $this->body($this->request('GET', $path, token: $author))['comments'];
        self::assertSame(['second', 'first'], array_column($comments, 'body'));
        self::assertTrue($comments[1]['author']['following']);
        self::assertFalse($this->body($this->request('GET', $path))['comments'][1]['author']['following']);

        self::assertSame(403, $this->request('DELETE', $path . '/' . $id, token: $other)->getStatusCode());
        self::assertSame(404, $this->request('DELETE', '/api/articles/' . $otherSlug . '/comments/' . $id, token: $author)->getStatusCode());
        self::assertSame(204, $this->request('DELETE', $path . '/' . $id, token: $author)->getStatusCode());
        self::assertSame(404, $this->request('DELETE', $path . '/' . $id, token: $author)->getStatusCode());
        self::assertSame(['second'], array_column($this->body($this->request('GET', $path))['comments'], 'body'));

        $this->request('DELETE', '/api/articles/' . $slug, token: $author);
        self::assertSame('0', pg_fetch_result($this->connection->read('SELECT count(*) FROM comments WHERE id = $1', [$this->body($second)['comment']['id']]), 0, 0));
        self::assertSame(404, $this->request('GET', $path)->getStatusCode());
    }
}
