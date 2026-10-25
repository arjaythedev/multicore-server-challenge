<?php

declare(strict_types=1);

use Composer\Autoload\ClassLoader;

// PHPStan runs from tools/, away from the server's autoloader. This gives it the server's classes,
// the namespace the rules and architecture tests live in, and PHPat, which PHPStan's own
// autoloader does not know about.
$autoloader = require \dirname(__DIR__) . '/vendor/autoload.php';
\assert($autoloader instanceof ClassLoader);
$autoloader->addPsr4('App\\Tests\\', __DIR__);
$autoloader->addPsr4('PHPat\\', \dirname(__DIR__) . '/tools/vendor/phpat/phpat/src');
require_once \dirname(__DIR__) . '/tools/vendor/phpat/phpat/helpers.php';
