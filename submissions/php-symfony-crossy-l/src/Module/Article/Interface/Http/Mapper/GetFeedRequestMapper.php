<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Query\GetFeed\GetFeedQuery;
use App\Module\Article\Interface\Http\Request\PageParameters;
use App\Shared\Domain\Security\CallerContext;
use Symfony\Component\HttpFoundation\Request;

/**
 * ?limit= and ?offset= choose the page.
 */
final class GetFeedRequestMapper
{
    public function toQuery(Request $request, CallerContext $caller): GetFeedQuery
    {
        $page = PageParameters::fromRequest($request);

        return new GetFeedQuery(caller: $caller, limit: $page->limit, offset: $page->offset);
    }
}
