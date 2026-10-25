<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Query\ListArticles\ListArticlesQuery;
use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Interface\Http\Request\PageParameters;
use App\Shared\Domain\Security\CallerContext;
use Symfony\Component\HttpFoundation\Request;

/**
 * ?tag=, ?author= and ?favorited= filter the list. Only the first of them that is given and not empty
 * applies, in that order. ?limit= and ?offset= choose the page.
 */
final class ListArticlesRequestMapper
{
    public function toQuery(Request $request, CallerContext $caller): ListArticlesQuery
    {
        $page = PageParameters::fromRequest($request);

        return new ListArticlesQuery(
            caller: $caller,
            filter: self::filter($request->query->all()),
            limit: $page->limit,
            offset: $page->offset,
        );
    }

    /**
     * @param array<array-key, mixed> $parameters
     */
    private static function filter(array $parameters): ArticleFilter
    {
        $tag = self::text($parameters, 'tag');
        $author = self::text($parameters, 'author');
        $favorited = self::text($parameters, 'favorited');

        return match (true) {
            $tag !== '' => ArticleFilter::byTag($tag),
            $author !== '' => ArticleFilter::byAuthor($author),
            $favorited !== '' => ArticleFilter::favoritedBy($favorited),
            default => ArticleFilter::none(),
        };
    }

    /**
     * A parameter given as one value; absent, or given as a list (?tag[]=x), it is empty.
     *
     * @param array<array-key, mixed> $parameters
     */
    private static function text(array $parameters, string $name): string
    {
        $value = $parameters[$name] ?? '';

        return \is_string($value) ? $value : '';
    }
}
