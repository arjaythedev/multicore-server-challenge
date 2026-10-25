<?php

declare(strict_types=1);

use Composer\Autoload\ClassLoader;

// The tests run on the server's own autoloader, plus the namespace the tests live in.
$autoloader = require \dirname(__DIR__) . '/vendor/autoload.php';
\assert($autoloader instanceof ClassLoader);
$autoloader->addPsr4('App\\Tests\\', __DIR__);

// Integration tests run against their own database, created from the dev seed by `task test-db`.
$databaseUrl = getenv('TEST_DATABASE_URL') ?: 'postgres://conduit:conduit@127.0.0.1:5432/conduit_phpunit';
$_SERVER['DATABASE_URL'] = $_ENV['DATABASE_URL'] = $databaseUrl;
$_SERVER['JWT_SECRET'] = $_ENV['JWT_SECRET'] = 'multicore-server-challenge';
