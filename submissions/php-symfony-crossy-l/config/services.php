<?php

declare(strict_types=1);

namespace Symfony\Component\DependencyInjection\Loader\Configurator;

use App\Module\Article\Application\Port\ArticleReadServiceInterface;
use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Module\Article\Application\Service\ArticleReadService;
use App\Module\Article\Application\Service\ArticleWriteService;
use App\Module\Article\Domain\Repository\ArticlePageRepositoryInterface;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Module\Article\Domain\Repository\FavoriteRepositoryInterface;
use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgArticlePageRepository;
use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgArticleRepository;
use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgFavoriteRepository;
use App\Module\Comment\Application\Port\CommentReadServiceInterface;
use App\Module\Comment\Application\Port\CommentWriteServiceInterface;
use App\Module\Comment\Application\Service\CommentReadService;
use App\Module\Comment\Application\Service\CommentWriteService;
use App\Module\Comment\Domain\Repository\CommentRepositoryInterface;
use App\Module\Comment\Infrastructure\Persistence\Pg\Repository\PgCommentRepository;
use App\Module\Profile\Application\Port\ProfileReadServiceInterface;
use App\Module\Profile\Application\Port\ProfileWriteServiceInterface;
use App\Module\Profile\Application\Service\ProfileReadService;
use App\Module\Profile\Application\Service\ProfileWriteService;
use App\Module\Profile\Domain\Repository\FollowRepositoryInterface;
use App\Module\Profile\Domain\Repository\ProfileRepositoryInterface;
use App\Module\Profile\Infrastructure\Persistence\Pg\Repository\PgFollowRepository;
use App\Module\Profile\Infrastructure\Persistence\Pg\Repository\PgProfileRepository;
use App\Module\Tag\Application\Port\TagReadServiceInterface;
use App\Module\Tag\Application\Service\TagReadService;
use App\Module\Tag\Domain\Repository\TagRepositoryInterface;
use App\Module\Tag\Infrastructure\Persistence\Pg\Repository\PgTagRepository;
use App\Module\User\Application\Port\UserReadServiceInterface;
use App\Module\User\Application\Port\UserWriteServiceInterface;
use App\Module\User\Application\Service\UserReadService;
use App\Module\User\Application\Service\UserWriteService;
use App\Module\User\Domain\Repository\UserRepositoryInterface;
use App\Module\User\Domain\Security\PasswordHasherInterface;
use App\Module\User\Infrastructure\Persistence\Pg\Repository\PgUserRepository;
use App\Module\User\Infrastructure\Security\BcryptPasswordHasher;
use App\Shared\Domain\Security\AccessTokenServiceInterface;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Shared\Infrastructure\Security\Hs256AccessTokenService;
use App\Shared\Infrastructure\Worker\OpenWorkerConnections;
use App\Shared\Infrastructure\Worker\TaskWorkers;
use App\Shared\Interface\Http\LeanHttpKernel;

return static function (ContainerConfigurator $container): void {
    $services = $container->services()
        ->defaults()
            ->autowire()
            ->autoconfigure();

    // Values and carriers that are built by the code that needs them, never injected.
    $services->load('App\\', '../src/')
        ->exclude([
            '../src/Module/*/Domain/Model/',
            '../src/Module/*/Domain/View/',
            '../src/Shared/Domain/Model/',
            '../src/Shared/Domain/View/',
            '../src/Shared/Domain/Security/CallerContext.php',
            '../src/Module/*/Application/Command/*/*Command.php',
            '../src/Module/*/Application/Query/*/*Query.php',
            '../src/Module/*/Application/Result/',
            '../src/Shared/Application/Result/',
            '../src/Module/*/Interface/Http/Request/',
            '../src/Module/*/Interface/Http/Response/',
            '../src/Shared/Interface/Http/Request/',
            '../src/Shared/Interface/Http/Response/',
            '../src/Kernel.php',
            '../src/Shared/Interface/Http/LeanHeaderBag.php',
            // Built by the server script and by the connection pool, not injected.
            '../src/Shared/Infrastructure/Server/',
            '../src/Shared/Infrastructure/Persistence/Pg/PgLink.php',
            '../src/Shared/Infrastructure/Persistence/Pg/Batch/',
        ]);

    // Connections to Postgres per worker; the server sets it, tests and console commands use one.
    $container->parameters()->set('app.pg_connections', 1);

    $services->set(PgConnection::class)
        ->arg('$databaseUrl', env('DATABASE_URL'))
        ->arg('$size', env('PG_CONNECTIONS')->default('app.pg_connections')->int());

    $services->set(Hs256AccessTokenService::class)
        ->arg('$secret', env('JWT_SECRET'));

    // The server script starts each worker through this one.
    $services->set(OpenWorkerConnections::class)
        ->public();

    // The server script hands it the server, whose task workers run the jobs.
    $services->set(TaskWorkers::class)
        ->public();

    // The server script gets the kernel by this name.
    $services->alias('http_kernel', LeanHttpKernel::class)
        ->public();

    $services->alias(AccessTokenServiceInterface::class, Hs256AccessTokenService::class);

    $services->alias(TagRepositoryInterface::class, PgTagRepository::class);
    $services->alias(TagReadServiceInterface::class, TagReadService::class);

    $services->alias(UserRepositoryInterface::class, PgUserRepository::class);
    $services->alias(PasswordHasherInterface::class, BcryptPasswordHasher::class);
    $services->alias(UserReadServiceInterface::class, UserReadService::class);
    $services->alias(UserWriteServiceInterface::class, UserWriteService::class);

    $services->alias(ProfileRepositoryInterface::class, PgProfileRepository::class);
    $services->alias(FollowRepositoryInterface::class, PgFollowRepository::class);
    $services->alias(ProfileReadServiceInterface::class, ProfileReadService::class);
    $services->alias(ProfileWriteServiceInterface::class, ProfileWriteService::class);

    $services->alias(ArticleRepositoryInterface::class, PgArticleRepository::class);
    $services->alias(ArticlePageRepositoryInterface::class, PgArticlePageRepository::class);
    $services->alias(FavoriteRepositoryInterface::class, PgFavoriteRepository::class);
    $services->alias(ArticleReadServiceInterface::class, ArticleReadService::class);
    $services->alias(ArticleWriteServiceInterface::class, ArticleWriteService::class);

    $services->alias(CommentRepositoryInterface::class, PgCommentRepository::class);
    $services->alias(CommentReadServiceInterface::class, CommentReadService::class);
    $services->alias(CommentWriteServiceInterface::class, CommentWriteService::class);
};
