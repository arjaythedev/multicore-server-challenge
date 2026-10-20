#!/usr/bin/env perl
use Mojo::Base -strict;

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use lib dirname(abs_path($0)) . '/lib';

use Mojolicious::Commands;

Mojolicious::Commands->start_app('Conduit');
