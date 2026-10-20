#!/usr/bin/env perl
# Minimal Hypnotoad launcher (a copy of the `hypnotoad` executable shipped with Mojolicious),
# so start.sh does not depend on where the distro put that executable.
use Mojo::Base -strict;

use Mojo::Server::Hypnotoad;
use Mojo::Util qw(extract_usage getopt);

getopt
  'f|foreground' => \$ENV{HYPNOTOAD_FOREGROUND},
  'h|help'       => \my $help,
  's|stop'       => \$ENV{HYPNOTOAD_STOP},
  't|test'       => \$ENV{HYPNOTOAD_TEST};

die extract_usage if $help || !(my $app = shift || $ENV{HYPNOTOAD_APP});
Mojo::Server::Hypnotoad->new->run($app);
