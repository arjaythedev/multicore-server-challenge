package Conduit;
use Mojo::Base 'Mojolicious', -signatures;

# Conduit (RealWorld) API: Mojolicious + DBI/DBD::Pg. Contract: SPEC.md.

use DBI ();
use Mojo::JSON qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64 decode_base64);
use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash);

my $TOKEN_TTL_S = 30 * 24 * 3600;
my $BCRYPT_COST = 10;
my $INT64_MAX   = 9223372036854775807;

sub startup ($self) {

  # Hypnotoad: one worker per core, unlimited connections per worker (tens of thousands of
  # keep-alive sockets), idle keep-alives held open > 65 s so Nginx never races a closed socket.
  # MOJO_LISTEN also drives `conduit.pl daemon` for local development.
  $ENV{MOJO_LISTEN} ||= 'http://' . ($ENV{HOST} // '127.0.0.1') . ':' . ($ENV{PORT} // 3000);
  $self->config(hypnotoad => {
    listen             => [$ENV{MOJO_LISTEN}],
    workers            => _nproc(),
    accepts            => 0,
    keep_alive_requests => 1_000_000,
    inactivity_timeout => 75,
    heartbeat_interval => 15,
  });

  # Errors use the RealWorld shape: {"errors": {"body": ["..."]}}. Covers router 404/405 too.
  $self->hook(before_render => sub ($c, $args) {
    return if ($args->{status} // 0) < 400;
    $args->{json} = {errors => {body => ['error']}};
    delete @{$args}{qw(template data text)};
  });

  $self->helper(db => \&_db);
  $self->helper(exception_422 => sub ($c) {
    $c->render(json => {errors => {body => ['validation error']}}, status => 422);
  });

  my $r = $self->routes;

  # --- users and auth
  $r->post('/api/users')->to('user#register');
  $r->post('/api/users/login')->to('user#login');
  $r->get('/api/user')->to('user#get');
  $r->put('/api/user')->to('user#update');

  # --- profiles
  $r->get('/api/profiles/:username')->to('user#profile');
  $r->post('/api/profiles/<username>/follow')->to('user#follow');
  $r->delete('/api/profiles/<username>/follow')->to('user#unfollow');

  # --- articles
  $r->get('/api/articles/feed')->to('article#feed');
  $r->get('/api/articles')->to('article#list');
  $r->post('/api/articles')->to('article#create');
  $r->get('/api/articles/:slug')->to('article#get');
  $r->put('/api/articles/:slug')->to('article#update');
  $r->delete('/api/articles/:slug')->to('article#delete');
  $r->post('/api/articles/<slug>/favorite')->to('article#favorite');
  $r->delete('/api/articles/<slug>/favorite')->to('article#unfavorite');

  # --- comments
  $r->get('/api/articles/<slug>/comments')->to('comment#list');
  $r->post('/api/articles/<slug>/comments')->to('comment#create');
  $r->delete('/api/articles/<slug>/comments/<id:num>')->to('comment#delete');

  # --- tags
  $r->get('/api/tags')->to('tag#list');
}

# ---------------------------------------------------------------- database

{
  my $dbh;

  sub _db ($c) {
    return $dbh if $dbh && $dbh->{Active} && $dbh->pg_ping == 1;
    my $url = $ENV{DATABASE_URL}
      or die 'DATABASE_URL is not set';
    my ($user, $pass, $host, $port, $name) = $url =~ m{^postgres(?:ql)?://([^:/@]+):([^:/@]*)@([^:/@]+)(?::(\d+))?/([^/?]+)}
      or die "cannot parse DATABASE_URL";
    $dbh = DBI->connect(
      "dbi:Pg:dbname=$name;host=$host;port=" . ($port // 5432) . ';gssencmode=disable',
      $user, $pass,
      {AutoCommit => 1, RaiseError => 1, PrintError => 0, pg_server_prepare => 1},
    );
    $dbh->do("SET TIME ZONE 'UTC'");    # session-level, allowed by rule 2
    return $dbh;
  }
}

# ---------------------------------------------------------------- auth

sub _new_token ($uid) {
  my $now  = time;
  my $h    = _b64url(encode_json({alg => 'HS256', typ => 'JWT'}));
  my $p    = _b64url(encode_json({sub => "$uid", iat => $now, exp => $now + $TOKEN_TTL_S}));
  my $sig  = hmac_sha256("$h.$p", $ENV{JWT_SECRET});
  return "$h.$p." . _b64url($sig);
}

# Returns (uid, token) for a valid Token header, (0, undef) for no header, nothing for invalid.
sub _auth ($c) {
  my $header = $c->req->headers->authorization;
  return (0, undef) unless defined $header;
  $header =~ /^Token (\S+)$/ or return;
  my $token = $1;

  my @parts = split /\./, $token, -1;
  return unless @parts == 3;
  my $header_json = _b64url_dec($parts[0]);
  my $payload     = _b64url_dec($parts[1]);
  my $sig         = _b64url_dec($parts[2]);
  return unless defined $header_json && defined $payload && defined $sig;
  my $hdr = eval { decode_json($header_json) } or return;
  return unless ($hdr->{alg} // '') eq 'HS256';
  return unless hmac_sha256("$parts[0].$parts[1]", $ENV{JWT_SECRET}) eq $sig;
  my $claims = eval { decode_json($payload) } or return;
  return unless ($claims->{exp} // 0) > time;
  my $sub = _req_str($claims->{sub}) // '';
  return unless $sub =~ /^\d{1,19}$/ && $sub ne '0' && $sub <= $INT64_MAX;
  return ($sub, $token);
}

# uid for required endpoints (renders 401 and returns undef on failure).
sub _auth_required ($c) {
  my ($uid, $token) = _auth($c);
  if (!$uid) {
    $c->render(json => {errors => {body => ['unauthorized']}}, status => 401);
    return;
  }
  return wantarray ? ($uid, $token) : $uid;
}

# For auth-optional endpoints: no header means anonymous; present but invalid means 401.
sub _auth_optional ($c) {
  return (0, undef) unless defined $c->req->headers->authorization;
  my ($uid, $token) = _auth($c);
  if (!$uid) {
    $c->render(json => {errors => {body => ['unauthorized']}}, status => 401);
    return;
  }
  return ($uid, $token);
}

sub _b64url ($bytes) {
  my $b64 = encode_base64($bytes, '');
  $b64 =~ tr[+/][-_];
  $b64 =~ s/=+\z//;
  return $b64;
}

sub _b64url_dec ($str) {
  my $b64 = $str;
  $b64 =~ tr[-_][+/];
  $b64 = "$b64" . '=' x ((4 - length($b64) % 4) % 4);
  return eval { decode_base64($b64) };
}

# ---------------------------------------------------------------- bcrypt

sub _b64_bcrypt ($bytes) {
  my $b64 = encode_base64($bytes, '');
  $b64 =~ s/=+\z//;
  $b64 =~ tr[A-Za-z0-9+/][./A-Za-z0-9];
  return $b64;
}

sub _b64_bcrypt_dec ($str) {
  my $b64 = $str;
  $b64 =~ tr[./A-Za-z0-9][A-Za-z0-9+/];
  $b64 = "$b64" . '=' x ((4 - length($b64) % 4) % 4);
  return decode_base64($b64);
}

sub _bcrypt_hash ($password) {
  my $salt;
  open my $fh, '<:raw', '/dev/urandom' or die $!;
  sysread($fh, $salt, 16) == 16 or die 'short read from /dev/urandom';
  my $digest = bcrypt_hash({key_nul => 1, cost => $BCRYPT_COST, salt => $salt}, encode_utf8($password));
  return sprintf('$2a$%02d$%s%s', $BCRYPT_COST, _b64_bcrypt($salt), _b64_bcrypt($digest));
}

sub _bcrypt_check ($password, $stored) {
  my ($cost, $salt, $digest) = $stored =~ /^\$2[aby]\$(\d{2})\$([.\/A-Za-z0-9]{22})([.\/A-Za-z0-9]{31})$/
    or return 0;
  my $computed = bcrypt_hash({key_nul => 1, cost => $cost, salt => _b64_bcrypt_dec($salt)},
    encode_utf8($password));
  return _b64_bcrypt($computed) eq $digest;
}

sub encode_utf8 ($str) {
  require Encode;
  return Encode::encode('UTF-8', $str);
}

# ---------------------------------------------------------------- shared response pieces

sub _iso ($ts) {
  # RFC 3339 UTC, exactly 3 fractional digits (truncated), 'Z'.
  my ($d, $t, $f) = $ts =~ /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?/ or return $ts;
  return "${d}T${t}." . substr(($f // '') . '000', 0, 3) . 'Z';
}

sub _user_json ($row, $token) {
  return {
    email    => $row->{email},
    token    => $token,
    username => $row->{username},
    bio      => $row->{bio},
    image    => $row->{image},
  };
}

sub _profile_json ($row, $following) {
  return {
    username  => $row->{username},
    bio       => $row->{bio},
    image     => $row->{image},
    following => $following ? \1 : \0,
  };
}

sub _article_json ($row, $with_body) {
  my $article = {
    slug        => $row->{slug},
    title       => $row->{title},
    description => $row->{description},
  };
  $article->{body} = $row->{body} if $with_body;
  $article->{tagList}       = $row->{tag_list} // [];
  $article->{createdAt}     = _iso($row->{created_at});
  $article->{updatedAt}     = _iso($row->{updated_at});
  $article->{favorited}     = $row->{favorited} ? \1 : \0;
  $article->{favoritesCount} = 0 + $row->{favorites_count};
  $article->{author}        = _profile_json($row, $row->{following});
  return $article;
}

sub _comment_json ($row, $following) {
  return {
    id        => 0 + $row->{id},
    createdAt => _iso($row->{created_at}),
    updatedAt => _iso($row->{updated_at}),
    body      => $row->{body},
    author    => _profile_json($row, $following),
  };
}

# Body validation: a non-empty JSON string, else 422. JSON numbers/bools are rejected via the
# SV's string flag (Mojo::JSON decodes them without it), not by looks_like_number.
sub _req_str ($v) {
  return undef unless defined $v && !ref $v;
  return undef unless _is_string($v);
  return length $v ? $v : undef;
}

# For PATCH-style endpoints: absent/null => undef, any string (even empty) => value,
# anything else (JSON number/bool/object) => "\0invalid", which the caller turns into a 422.
sub _str_field ($v) {
  return undef if !defined $v;
  return $v if !ref $v && _is_string($v);
  return "\0invalid";
}

sub _is_string ($v) {
  require B;
  return (B::svref_2object(\$v)->FLAGS & B::SVf_POK()) ? 1 : 0;
}

# bcrypt only uses the first 72 bytes; the suite expects longer passwords to be a 422.
sub _password_ok ($password) {
  require Encode;
  return length(Encode::encode('UTF-8', $password)) <= 72;
}

sub _error ($c, $status, $msg = 'error') {
  $c->render(json => {errors => {body => [$msg]}}, status => $status);
  return;
}

# limit (default 20, 1-100) and offset (default 0, >= 0), else 422. Renders the error itself.
sub _page ($c) {
  my ($limit, $offset) = (20, 0);
  if (defined(my $s = $c->param('limit'))) {
    $s =~ /^[0-9]+$/ && $s >= 1 && $s <= 100 && length($s) <= 10 or return;
    $limit = 0 + $s;
  }
  if (defined(my $s = $c->param('offset'))) {
    $s =~ /^[0-9]+$/ && length($s) <= 10 or return;
    $offset = 0 + $s;
  }
  return ($limit, $offset);
}

sub _nproc () {
  my $n;
  if (open my $fh, '<', '/proc/cpuinfo') { $n++ while <$fh> =~ /^processor\s*:\s*\d/; }
  elsif (my $out = `nproc 2>/dev/null`) { $n = $out + 0; }
  elsif (my $ncpu = `sysctl -n hw.ncpu 2>/dev/null`) { $n = $ncpu + 0; }
  return $n && $n <= 64 ? $n : 1;
}

1;
