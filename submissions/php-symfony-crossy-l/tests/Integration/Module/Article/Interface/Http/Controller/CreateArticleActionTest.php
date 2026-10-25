<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Article\Interface\Http\Controller;

use App\Tests\Integration\Shared\AbstractControllerTestCase;

final class CreateArticleActionTest extends AbstractControllerTestCase
{
    public function testTagsFiltersPaginationFavoritesAndFeedReflectWrites(): void
    {
        $author = $this->register('article-author');
        $viewer = $this->register('article-viewer');
        $tags = ['z-test', 'a,quoted"tag', 'back\\slash', 'a,quoted"tag'];
        $first = $this->createArticle($author, 'First Title!', $tags);
        $second = $this->createArticle($author, 'Second Title');
        $third = $this->createArticle($author, 'Third Title', ['z-test']);

        $single = $this->body($this->request('GET', '/api/articles/' . $first))['article'];
        self::assertSame(['a,quoted"tag', 'back\\slash', 'z-test'], $single['tagList']);
        self::assertMatchesRegularExpression('/^first-title-\d+$/', $first);
        self::assertMatchesRegularExpression('/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/', $single['createdAt']);

        $page = $this->body($this->request('GET', '/api/articles?author=article-author&limit=1&offset=1'));
        self::assertSame(3, $page['articlesCount']);
        self::assertSame([$second], array_column($page['articles'], 'slug'));
        self::assertArrayNotHasKey('body', $page['articles'][0]);
        $tagPage = $this->body($this->request('GET', '/api/articles?tag=z-test&author=missing'));
        self::assertSame(2, $tagPage['articlesCount']);
        self::assertSame([$third, $first], array_column($tagPage['articles'], 'slug'));
        $empty = $this->body($this->request('GET', '/api/articles?author=article-author&offset=999'));
        self::assertSame([], $empty['articles']);
        self::assertSame(3, $empty['articlesCount']);

        foreach (['POST', 'POST', 'DELETE', 'DELETE'] as $method) {
            $favorite = $this->request($method, '/api/articles/' . $first . '/favorite', token: $viewer);
            self::assertSame(200, $favorite->getStatusCode());
            self::assertSame($method === 'POST', $this->body($favorite)['article']['favorited']);
            self::assertSame($method === 'POST' ? 1 : 0, $this->body($favorite)['article']['favoritesCount']);
            $favorites = $this->body($this->request('GET', '/api/articles?favorited=article-viewer', token: $viewer));
            self::assertSame($method === 'POST' ? [$first] : [], array_column($favorites['articles'], 'slug'));
            self::assertFalse($this->body($this->request('GET', '/api/articles/' . $first))['article']['favorited']);
        }

        self::assertSame([], $this->body($this->request('GET', '/api/articles/feed', token: $viewer))['articles']);
        $this->request('POST', '/api/profiles/article-author/follow', token: $viewer);
        $feed = $this->body($this->request('GET', '/api/articles/feed?limit=2&offset=1', token: $viewer));
        self::assertSame(3, $feed['articlesCount']);
        self::assertSame([$second, $first], array_column($feed['articles'], 'slug'));
        self::assertTrue($feed['articles'][0]['author']['following']);
        self::assertSame(1000, $this->body($this->request('GET', '/api/articles?limit=1'))['articlesCount']);
    }

    public function testOnlyTheAuthorCanUpdateOrDeleteAndRenamingInvalidatesTheOldSlug(): void
    {
        $author = $this->register('article-owner');
        $other = $this->register('article-other');
        $slug = $this->createArticle($author, 'Original', ['kept-tag']);
        $path = '/api/articles/' . $slug;

        self::assertSame(403, $this->request('PUT', $path, ['article' => ['title' => 'forbidden']], $other)->getStatusCode());
        self::assertSame(403, $this->request('DELETE', $path, token: $other)->getStatusCode());
        $updated = $this->request('PUT', $path, ['article' => ['title' => 'New Title', 'body' => 'new body', 'tagList' => ['ignored']]], $author);
        self::assertSame(200, $updated->getStatusCode());
        $article = $this->body($updated)['article'];
        self::assertSame('new body', $article['body']);
        self::assertSame(['kept-tag'], $article['tagList']);
        self::assertNotSame($slug, $article['slug']);
        self::assertSame(404, $this->request('GET', $path)->getStatusCode());
        self::assertSame(204, $this->request('DELETE', '/api/articles/' . $article['slug'], token: $author)->getStatusCode());
        self::assertSame(404, $this->request('GET', '/api/articles/' . $article['slug'])->getStatusCode());
    }
}
