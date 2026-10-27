#!/usr/bin/env perl
# Conduit (RealWorld) on a hand-rolled prefork HTTP/1.1 server.
#
# No framework: each worker is an EV (libev/epoll) event loop over its keep-alive client
# sockets with one blocking DBI/DBD::Pg connection. The process binds :80 itself and holds
# every browser connection, so there is no reverse-proxy hop in the request path.
use strict;
use warnings;
no warnings 'uninitialized';

use Socket qw(PF_INET SOCK_STREAM SOL_SOCKET SO_REUSEADDR IPPROTO_TCP TCP_NODELAY
              AF_INET inet_aton sockaddr_in);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use EV;
use DBI ();
use JSON::XS ();
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64 decode_base64);
use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash);
use Encode ();
use B ();

my $JSON = JSON::XS->new->allow_nonref;

my $TOKEN_TTL   = 30 * 24 * 3600;
my $BCRYPT_COST = 10;
my $INT64_MAX   = 9223372036854775807;
my $MAX_HEAD    = 64 * 1024;
my $MAX_BODY    = 2 * 1024 * 1024;
my $IDLE_SECS   = 75;

my $JWT_HEADER = _b64url('{"alg":"HS256","typ":"JWT"}');

my %REASON = (
    200 => 'OK', 201 => 'Created', 204 => 'No Content',
    400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden',
    404 => 'Not Found', 405 => 'Method Not Allowed', 422 => 'Unprocessable Entity',
    500 => 'Internal Server Error',
);

my %ERR_BODY = (
    400 => '{"errors":{"body":["bad request"]}}',
    401 => '{"errors":{"body":["unauthorized"]}}',
    403 => '{"errors":{"body":["forbidden"]}}',
    404 => '{"errors":{"body":["not found"]}}',
    405 => '{"errors":{"body":["method not allowed"]}}',
    422 => '{"errors":{"body":["validation error"]}}',
    500 => '{"errors":{"body":["server error"]}}',
);

# ---------------------------------------------------------------- SQL

my $ARTICLE_LIST_SELECT = <<'SQL';
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
              FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       fv.fc AS favorites_count,
       fv.fav AS favorited,
       u.username, u.bio, u.image,
       COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo
                                          WHERE fo.follower_id = ?)), false) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (SELECT count(*) AS fc,
                            COALESCE(bool_or(f.user_id = ?), false) AS fav
                       FROM favorites f WHERE f.article_id = a.id) fv ON true
SQL

my $ARTICLE_FULL_SELECT = $ARTICLE_LIST_SELECT;
$ARTICLE_FULL_SELECT =~ s/a\.created_at/a.body, a.created_at/;

my $ORDER_PAGE = ' ORDER BY a.id DESC LIMIT ? OFFSET ?';
my $SLUGIFY    = q{trim(both '-' from lower(regexp_replace(?, '[^A-Za-z0-9]+', '-', 'g')))};

my $SQL_ARTICLE_BY_ID = $ARTICLE_FULL_SELECT . ' WHERE a.id = ?';
my $SQL_ARTICLE_BY_SLUG = $ARTICLE_FULL_SELECT . ' WHERE a.slug = ?';
my $SQL_ARTICLE_OWNED  = 'SELECT id, author_id FROM articles WHERE slug = ?';

my $SQL_ARTICLE_LIST_NONE = $ARTICLE_LIST_SELECT . $ORDER_PAGE;
my $SQL_ARTICLE_LIST_TAG =
    $ARTICLE_LIST_SELECT
  . ' WHERE a.id IN (SELECT at.article_id FROM article_tags at'
  . ' WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?)'
  . ' ORDER BY at.article_id DESC LIMIT ? OFFSET ?) ORDER BY a.id DESC';
my $SQL_ARTICLE_LIST_AUTHOR =
    $ARTICLE_LIST_SELECT
  . ' WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = ?)'
  . $ORDER_PAGE;
my $SQL_ARTICLE_LIST_FAV =
    $ARTICLE_LIST_SELECT
  . ' WHERE a.id IN (SELECT f.article_id FROM favorites f'
  . ' WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?)'
  . ' ORDER BY f.article_id DESC LIMIT ? OFFSET ?) ORDER BY a.id DESC';
my $SQL_ARTICLE_FEED =
    $ARTICLE_LIST_SELECT
  . ' WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL'
  . '   (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id'
  . '    ORDER BY a2.id DESC LIMIT (?::int + ?::int)) x'
  . '  WHERE fo.follower_id = ? ORDER BY x.id DESC LIMIT ? OFFSET ?) ORDER BY a.id DESC';

my $SQL_COUNT_ALL     = 'SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s';
my $SQL_COUNT_TAG     = 'SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?) LIMIT 1000) s';
my $SQL_COUNT_AUTHOR  = 'SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = ?) LIMIT 1000) s';
my $SQL_COUNT_FAV     = 'SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?) LIMIT 1000) s';
my $SQL_COUNT_FEED    = 'SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ?) LIMIT 1000) s';

my $SQL_INSERT_ARTICLE =
    'INSERT INTO articles (id, slug, author_id, title, description, body)'
  . " SELECT n.id, $SLUGIFY || '-' || n.id, ?, ?, ?, ?"
  . q{ FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id};
my $SQL_INSERT_TAGS = 'INSERT INTO tags (name) SELECT DISTINCT unnest(?::text[]) ON CONFLICT (name) DO NOTHING';
my $SQL_INSERT_ARTICLE_TAGS = 'INSERT INTO article_tags (article_id, tag_id) SELECT ?, t.id FROM tags t WHERE t.name = ANY(?::text[])';
my $SQL_UPDATE_ARTICLE =
    'UPDATE articles SET title = COALESCE(?, title), description = COALESCE(?, description),'
  . ' body = COALESCE(?, body),'
  . " slug = CASE WHEN ?::text IS NULL THEN slug ELSE $SLUGIFY || '-' || id END,"
  . ' updated_at = now() WHERE id = ?';
my $SQL_DELETE_ARTICLE = 'DELETE FROM articles WHERE id = ?';

my $SQL_FAV_INSERT_BY_SLUG =
    'WITH a AS (SELECT id FROM articles WHERE slug = ?),'
  . ' ins AS (INSERT INTO favorites (user_id, article_id) SELECT ?, id FROM a ON CONFLICT DO NOTHING)'
  . ' SELECT id FROM a';
my $SQL_FAV_DELETE_BY_SLUG =
    'WITH a AS (SELECT id FROM articles WHERE slug = ?),'
  . ' del AS (DELETE FROM favorites WHERE user_id = ? AND article_id IN (SELECT id FROM a))'
  . ' SELECT id FROM a';

my $SQL_COMMENTS_BY_SLUG =
    'WITH a AS (SELECT id FROM articles WHERE slug = ?)'
  . ' SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,'
  . ' EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = c.author_id) AS following'
  . ' FROM a LEFT JOIN comments c ON c.article_id = a.id'
  . ' LEFT JOIN users u ON u.id = c.author_id'
  . ' ORDER BY c.created_at DESC, c.id DESC LIMIT 100';
my $SQL_INSERT_COMMENT =
    'WITH c AS (INSERT INTO comments (article_id, author_id, body)'
  . ' SELECT a.id, ?, ? FROM articles a WHERE a.slug = ?'
  . ' RETURNING id, body, created_at, updated_at, author_id)'
  . ' SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image'
  . ' FROM c JOIN users u ON u.id = c.author_id';
my $SQL_COMMENT_OWNER =
    'SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id'
  . ' WHERE c.id = ? AND a.slug = ?';
my $SQL_DELETE_COMMENT = 'DELETE FROM comments WHERE id = ?';

my $SQL_USER_BY_ID    = 'SELECT id, username, email, bio, image FROM users WHERE id = ?';
my $SQL_USER_BY_EMAIL = 'SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ?';
my $SQL_USER_INSERT   = 'INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?) RETURNING id, username, email, bio, image';
my $SQL_USER_UPDATE =
    'UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),'
  . ' password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)'
  . ' WHERE id = ? RETURNING id, username, email, bio, image';

my $SQL_PROFILE =
    'SELECT u.id, u.username, u.bio, u.image,'
  . ' EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = u.id) AS following'
  . ' FROM users u WHERE u.username = ?';
my $SQL_FOLLOW_INSERT_BY_NAME =
    'WITH t AS (SELECT id, username, bio, image FROM users WHERE username = ?),'
  . ' ins AS (INSERT INTO follows (follower_id, followee_id) SELECT ?, id FROM t ON CONFLICT DO NOTHING)'
  . ' SELECT id, username, bio, image FROM t';
my $SQL_FOLLOW_DELETE_BY_NAME =
    'WITH t AS (SELECT id, username, bio, image FROM users WHERE username = ?),'
  . ' del AS (DELETE FROM follows WHERE follower_id = ? AND followee_id IN (SELECT id FROM t))'
  . ' SELECT id, username, bio, image FROM t';

my $SQL_TAGS = 'SELECT name FROM tags ORDER BY name';

# ---------------------------------------------------------------- helpers

sub _b64url {
    my $b64 = encode_base64($_[0], '');
    $b64 =~ tr[+/][-_];
    $b64 =~ s/=+\z//;
    return $b64;
}

sub _b64url_dec {
    my $b64 = $_[0];
    $b64 =~ tr[-_][+/];
    $b64 .= '=' x ((4 - length($b64) % 4) % 4);
    return decode_base64($b64);
}

sub _b64_bcrypt {
    my $b64 = encode_base64($_[0], '');
    $b64 =~ s/=+\z//;
    $b64 =~ tr[A-Za-z0-9+/][./A-Za-z0-9];
    return $b64;
}

sub _b64_bcrypt_dec {
    my $b64 = $_[0];
    $b64 =~ tr[./A-Za-z0-9][A-Za-z0-9+/];
    $b64 .= '=' x ((4 - length($b64) % 4) % 4);
    return decode_base64($b64);
}

sub _bcrypt_hash {
    my $salt;
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    sysread($fh, $salt, 16) == 16 or die 'short urandom read';
    close $fh;
    my $digest = bcrypt_hash(
        { key_nul => 1, cost => $BCRYPT_COST, salt => $salt },
        Encode::encode('UTF-8', $_[0])
    );
    return sprintf('$2a$%02d$%s%s', $BCRYPT_COST, _b64_bcrypt($salt), _b64_bcrypt($digest));
}

sub _bcrypt_check {
    my ($password, $stored) = @_;
    my ($cost, $salt, $digest) = $stored =~ /^\$2[aby]\$(\d{2})\$([.\/A-Za-z0-9]{22})([.\/A-Za-z0-9]{31})$/
      or return 0;
    my $computed = bcrypt_hash(
        { key_nul => 1, cost => $cost, salt => _b64_bcrypt_dec($salt) },
        Encode::encode('UTF-8', $password)
    );
    return _b64_bcrypt($computed) eq $digest;
}

sub _password_ok {
    return length(Encode::encode('UTF-8', $_[0])) <= 72;
}

sub _iso {
    my $ts = $_[0];
    return $ts unless $ts =~ /^(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)(?:\.(\d+))?/;
    my $f = defined $3 ? $3 : '';
    return $1 . 'T' . $2 . '.' . substr($f . '000', 0, 3) . 'Z';
}

sub _is_string {
    return (B::svref_2object(\$_[0])->FLAGS & B::SVf_POK()) ? 1 : 0;
}

sub _req_str {
    my $v = $_[0];
    return undef unless defined $v && !ref $v && _is_string($v);
    return length($v) ? $v : undef;
}

sub _str_field {
    my $v = $_[0];
    return undef if !defined $v;
    return $v if !ref $v && _is_string($v);
    return "\0invalid";
}

sub _user_json {
    my ($row, $token) = @_;
    return {
        email    => $row->{email},
        token    => $token,
        username => $row->{username},
        bio      => $row->{bio},
        image    => $row->{image},
    };
}

sub _profile_json {
    my ($row, $following) = @_;
    return {
        username  => $row->{username},
        bio       => $row->{bio},
        image     => $row->{image},
        following => $following ? \1 : \0,
    };
}

sub _article_json {
    my ($row, $with_body) = @_;
    my $a = {
        slug        => $row->{slug},
        title       => $row->{title},
        description => $row->{description},
        tagList     => $row->{tag_list} || [],
        createdAt   => _iso($row->{created_at}),
        updatedAt   => _iso($row->{updated_at}),
        favorited   => $row->{favorited} ? \1 : \0,
        favoritesCount => 0 + $row->{favorites_count},
        author      => {
            username  => $row->{username},
            bio       => $row->{bio},
            image     => $row->{image},
            following => $row->{following} ? \1 : \0,
        },
    };
    $a->{body} = $row->{body} if $with_body;
    return $a;
}

sub _comment_json {
    my ($row, $following) = @_;
    return {
        id        => 0 + $row->{id},
        createdAt => _iso($row->{created_at}),
        updatedAt => _iso($row->{updated_at}),
        body      => $row->{body},
        author    => {
            username  => $row->{username},
            bio       => $row->{bio},
            image     => $row->{image},
            following => $following ? \1 : \0,
        },
    };
}

sub _new_token {
    my $uid = $_[0];
    my $now = time;
    my $p = _b64url('{"sub":"' . $uid . '","iat":' . $now . ',"exp":' . ($now + $TOKEN_TTL) . '}');
    my $sig = _b64url(hmac_sha256("$JWT_HEADER.$p", $ENV{JWT_SECRET}));
    return "$JWT_HEADER.$p.$sig";
}

# returns ($uid, $token) or () for a bad token
sub _auth_token {
    my $token = $_[0];
    my @parts = split /\./, $token, -1;
    return unless @parts == 3;
    my $hdr_raw = _b64url_dec($parts[0]);
    my $payload = _b64url_dec($parts[1]);
    my $sig     = _b64url_dec($parts[2]);
    return unless defined $hdr_raw && defined $payload && defined $sig;
    my $hdr = eval { $JSON->decode($hdr_raw) };
    return unless ref $hdr eq 'HASH' && (($hdr->{alg} // '') eq 'HS256');
    return unless hmac_sha256("$parts[0].$parts[1]", $ENV{JWT_SECRET}) eq $sig;
    # Regex instead of a second JSON decode on the hot path: the signature is already
    # verified, and exp/sub are still enforced.
    return unless $payload =~ /"exp"\s*:\s*(\d{1,19})/;
    return unless $1 > time;
    return unless $payload =~ /"sub"\s*:\s*"([^"]*)"/;
    my $sub = $1;
    return unless $sub =~ /^\d{1,19}$/ && $sub ne '0' && $sub <= $INT64_MAX;
    return ($sub, $token);
}

# ---------------------------------------------------------------- database

my ($DBH, %STH);

sub _db_connect {
    my $url = $ENV{DATABASE_URL} or die "DATABASE_URL is not set\n";
    my ($user, $pass, $host, $port, $name) =
      $url =~ m{^postgres(?:ql)?://([^:/@]+):([^:/@]*)@([^:/@]+)(?::(\d+))?/([^/?]+)}
      or die "cannot parse DATABASE_URL\n";
    $port //= 5432;
    $DBH = DBI->connect(
        "dbi:Pg:dbname=$name;host=$host;port=$port;gssencmode=disable",
        $user, $pass,
        { AutoCommit => 1, RaiseError => 1, PrintError => 0, pg_server_prepare => 1 },
    ) or die "DBI connect failed: $DBI::errstr\n";
    $DBH->do("SET TIME ZONE 'UTC'");
    $DBH->do("SET application_name = 'conduit-perl-raw'");
    $DBH->do("SET enable_seqscan = off");
}

sub _sth {
    my $sql = $_[0];
    return $STH{$sql} ||= $DBH->prepare($sql);
}

sub _rows {
    my ($sql, @args) = @_;
    my $sth = _sth($sql);
    $sth->execute(@args);
    return $sth->fetchall_arrayref({});
}

sub _row {
    my ($sql, @args) = @_;
    my $sth = _sth($sql);
    $sth->execute(@args);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return $row;
}

sub _val {
    my ($sql, @args) = @_;
    my $sth = _sth($sql);
    $sth->execute(@args);
    my ($v) = $sth->fetchrow_array;
    $sth->finish;
    return $v;
}

sub _do {
    my ($sql, @args) = @_;
    my $sth = _sth($sql);
    $sth->execute(@args);
    return $sth->rows;
}

# ---------------------------------------------------------------- request parsing

sub _unescape {
    my $s = $_[0];
    $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $s;
}

sub _parse_query {
    my $qs = $_[0];
    my %q;
    return \%q unless defined $qs && length $qs;
    for my $pair (split /[&;]/, $qs) {
        next unless length $pair;
        my ($k, $v) = split /=/, $pair, 2;
        $k = _unescape($k);
        $v = defined $v ? $v : '';
        $v =~ tr/+/ /;
        $v = _unescape($v);
        $q{$k} = $v unless exists $q{$k};
    }
    return \%q;
}

sub _page {
    my $q = $_[0];
    my ($limit, $offset) = (20, 0);
    if (exists $q->{limit}) {
        my $s = $q->{limit};
        return unless defined $s && $s =~ /^\d{1,10}$/ && $s >= 1 && $s <= 100;
        $limit = 0 + $s;
    }
    if (exists $q->{offset}) {
        my $s = $q->{offset};
        return unless defined $s && $s =~ /^\d{1,10}$/;
        $offset = 0 + $s;
    }
    return ($limit, $offset);
}

sub _respond_json {
    my ($status, $data) = @_;
    return ($status, $JSON->encode($data));
}

sub _err {
    my $status = $_[0];
    return ($status, $ERR_BODY{$status} // $ERR_BODY{500});
}

sub _handle {
    my ($method, $path, $query, $headers, $body) = @_;

    # ---- tags
    if ($path eq "/api/tags") {
        return _err(405) unless $method eq "GET";
        my $sth = _sth($SQL_TAGS);
        $sth->execute;
        my $rows = $sth->fetchall_arrayref;
        $sth->finish;
        return _respond_json(200, { tags => [ map { $_->[0] } @$rows ] });
    }

    # ---- users / auth
    if ($path eq '/api/users') {
        return _err(405) unless $method eq 'POST';
        return _register($body);
    }
    if ($path eq '/api/users/login') {
        return _err(405) unless $method eq 'POST';
        return _login($body);
    }
    if ($path eq '/api/user') {
        my ($uid, $token, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        return _err(401) unless $uid;
        if ($method eq 'GET') {
            my $row = _row($SQL_USER_BY_ID, $uid);
            return _err(401) unless $row;
            return _respond_json(200, { user => _user_json($row, $token) });
        }
        if ($method eq 'PUT') {
            return _update_user($uid, $token, $body);
        }
        return _err(405);
    }

    # ---- profiles
    if ($path =~ m{^/api/profiles/([^/]+)/follow$}) {
        my $username = _unescape($1);
        return _err(405) unless $method eq 'POST' || $method eq 'DELETE';
        my ($uid, undef, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        return _err(401) unless $uid;
        my $row = $method eq 'POST'
          ? _row($SQL_FOLLOW_INSERT_BY_NAME, $username, $uid)
          : _row($SQL_FOLLOW_DELETE_BY_NAME, $username, $uid);
        return _err(404) unless $row;
        return _respond_json(200, { profile => _profile_json($row, $method eq 'POST' ? 1 : 0) });
    }
    if ($path =~ m{^/api/profiles/([^/]+)$}) {
        return _err(405) unless $method eq 'GET';
        my $username = _unescape($1);
        my ($viewer, undef, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        my $row = _row($SQL_PROFILE, $viewer, $username);
        return _err(404) unless $row;
        return _respond_json(200, { profile => _profile_json($row, $row->{following}) });
    }

    # ---- articles: feed before :slug
    if ($path eq '/api/articles/feed') {
        return _err(405) unless $method eq 'GET';
        my ($uid, undef, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        return _err(401) unless $uid;
        my ($limit, $offset) = _page($query);
        return _err(422) unless defined $limit;
        my $rows = _rows($SQL_ARTICLE_FEED, $uid, $uid, $limit, $offset, $uid, $limit, $offset);
        my $count = _val($SQL_COUNT_FEED, $uid);
        return _respond_json(200, {
            articles => [ map { _article_json($_, 0) } @$rows ],
            articlesCount => 0 + $count,
        });
    }

    if ($path eq '/api/articles') {
        if ($method eq 'GET') {
            my ($viewer, undef, $bad) = _auth_optional($headers);
            return _err(401) if $bad;
            my ($limit, $offset) = _page($query);
            return _err(422) unless defined $limit;
            my ($tag, $author, $favorited) = @{$query}{qw(tag author favorited)};
            $tag = undef if defined $tag && !length $tag;
            $author = undef if defined $author && !length $author;
            $favorited = undef if defined $favorited && !length $favorited;

            my ($rows, $count);
            if (defined $tag) {
                $rows = _rows($SQL_ARTICLE_LIST_TAG, $viewer, $viewer, $tag, $limit, $offset);
                $count = _val($SQL_COUNT_TAG, $tag);
            } elsif (defined $author) {
                $rows = _rows($SQL_ARTICLE_LIST_AUTHOR, $viewer, $viewer, $author, $limit, $offset);
                $count = _val($SQL_COUNT_AUTHOR, $author);
            } elsif (defined $favorited) {
                $rows = _rows($SQL_ARTICLE_LIST_FAV, $viewer, $viewer, $favorited, $limit, $offset);
                $count = _val($SQL_COUNT_FAV, $favorited);
            } else {
                $rows = _rows($SQL_ARTICLE_LIST_NONE, $viewer, $viewer, $limit, $offset);
                $count = _val($SQL_COUNT_ALL);
            }
            return _respond_json(200, {
                articles => [ map { _article_json($_, 0) } @$rows ],
                articlesCount => 0 + $count,
            });
        }
        if ($method eq 'POST') {
            my ($uid, undef, $bad) = _auth_optional($headers);
            return _err(401) if $bad;
            return _err(401) unless $uid;
            return _create_article($uid, $body);
        }
        return _err(405);
    }

    if ($path =~ m{^/api/articles/([^/]+)/favorite$}) {
        my $slug = _unescape($1);
        return _err(405) unless $method eq 'POST' || $method eq 'DELETE';
        my ($uid, undef, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        return _err(401) unless $uid;
        my $article = $method eq 'POST'
          ? _row($SQL_FAV_INSERT_BY_SLUG, $slug, $uid)
          : _row($SQL_FAV_DELETE_BY_SLUG, $slug, $uid);
        return _err(404) unless $article;
        my $row = _row($SQL_ARTICLE_BY_ID, $uid, $uid, $article->{id});
        return _err(404) unless $row;
        return _respond_json(200, { article => _article_json($row, 1) });
    }

    if ($path =~ m{^/api/articles/([^/]+)/comments$}) {
        my $slug = _unescape($1);
        if ($method eq 'GET') {
            my ($viewer, undef, $bad) = _auth_optional($headers);
            return _err(401) if $bad;
            my $rows = _rows($SQL_COMMENTS_BY_SLUG, $slug, $viewer);
            return _err(404) unless @$rows;
            if (@$rows == 1 && !defined $rows->[0]{id}) {
                return _respond_json(200, { comments => [] });
            }
            return _respond_json(200, {
                comments => [ map { _comment_json($_, $_->{following}) } @$rows ],
            });
        }
        if ($method eq 'POST') {
            my ($uid, undef, $bad) = _auth_optional($headers);
            return _err(401) if $bad;
            return _err(401) unless $uid;
            return _create_comment($uid, $slug, $body);
        }
        return _err(405);
    }

    if ($path =~ m{^/api/articles/([^/]+)/comments/([^/]+)$}) {
        return _err(405) unless $method eq 'DELETE';
        my ($slug, $id) = (_unescape($1), _unescape($2));
        return _err(404) unless $id =~ /^\d{1,19}$/ && $id <= $INT64_MAX;
        my ($uid, undef, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        return _err(401) unless $uid;
        my $row = _row($SQL_COMMENT_OWNER, $id, $slug);
        return _err(404) unless $row;
        return _err(403) unless $row->{author_id} == $uid;
        _do($SQL_DELETE_COMMENT, $id);
        return (204, '');
    }

    if ($path =~ m{^/api/articles/([^/]+)$}) {
        my $slug = _unescape($1);
        my ($uid, undef, $bad) = _auth_optional($headers);
        return _err(401) if $bad;
        if ($method eq 'GET') {
            my $row = _row($SQL_ARTICLE_BY_SLUG, $uid, $uid, $slug);
            return _err(404) unless $row;
            return _respond_json(200, { article => _article_json($row, 1) });
        }
        return _err(401) unless $uid;
        if ($method eq 'PUT') {
            return _update_article($uid, $slug, $body);
        }
        if ($method eq 'DELETE') {
            my $row = _row($SQL_ARTICLE_OWNED, $slug);
            return _err(404) unless $row;
            return _err(403) unless $row->{author_id} == $uid;
            _do($SQL_DELETE_ARTICLE, $row->{id});
            return (204, '');
        }
        return _err(405);
    }

    return _err(404);
}

sub _auth_optional {
    my $headers = $_[0];
    return (0, undef, 0) unless exists $headers->{authorization};
    my $h = $headers->{authorization};
    return (undef, undef, 1) unless defined $h && $h =~ /^\s*Token\s+(\S+)\s*$/;
    my ($uid, $token) = _auth_token($1);
    return (undef, undef, 1) unless $uid;
    return ($uid, $token, 0);
}

# ---------------------------------------------------------------- endpoints

sub _register {
    my $body = $_[0];
    my $data = eval { $JSON->decode($body) };
    return _err(422) unless ref $data eq 'HASH';
    my $u = $data->{user};
    return _err(422) unless ref $u eq 'HASH';
    my ($username, $email, $password) = map { _req_str($u->{$_}) } qw(username email password);
    return _err(422) unless defined $username && defined $email && defined $password;
    return _err(422) unless _password_ok($password);

    my $row = eval { _row($SQL_USER_INSERT, $username, $email, _bcrypt_hash($password)) };
    if (!$row) {
        return _err(422) if ($DBI::state // '') eq '23505';
        die $@ if $@;
        return _err(500);
    }
    return _respond_json(201, { user => _user_json($row, _new_token($row->{id})) });
}

sub _login {
    my $body = $_[0];
    my $data = eval { $JSON->decode($body) };
    return _err(422) unless ref $data eq 'HASH';
    my $u = $data->{user};
    return _err(422) unless ref $u eq 'HASH';
    my ($email, $password) = map { _req_str($u->{$_}) } qw(email password);
    return _err(422) unless defined $email && defined $password;

    my $row = _row($SQL_USER_BY_EMAIL, $email);
    return _err(401) unless $row && _bcrypt_check($password, $row->{password_hash});
    return _respond_json(200, { user => _user_json($row, _new_token($row->{id})) });
}

sub _update_user {
    my ($uid, $token, $body) = @_;
    my $data = eval { $JSON->decode($body) };
    return _err(422) unless ref $data eq 'HASH';
    my $u = $data->{user};
    return _err(422) unless ref $u eq 'HASH';
    my %f = map { $_ => _str_field($u->{$_}) } qw(email username password bio image);
    return _err(422) if grep { defined && $_ eq "\0invalid" } values %f;
    return _err(422)
      if (defined($f{email}) && !length($f{email}))
      || (defined($f{username}) && !length($f{username}))
      || (defined($f{password}) && !length($f{password}))
      || (defined($f{password}) && !_password_ok($f{password}));
    my ($email, $username, $password, $bio, $image) = @f{qw(email username password bio image)};
    $password = _bcrypt_hash($password) if defined $password;

    my $row = eval {
        _row($SQL_USER_UPDATE, $email, $username, $password, $bio, $image, $uid);
    };
    if (!$row) {
        return _err(422) if ($DBI::state // '') eq '23505';
        die $@ if $@;
        return _err(401);
    }
    return _respond_json(200, { user => _user_json($row, $token) });
}

sub _create_article {
    my ($uid, $body) = @_;
    my $data = eval { $JSON->decode($body) };
    return _err(422) unless ref $data eq 'HASH';
    my $a = $data->{article};
    return _err(422) unless ref $a eq 'HASH';
    my ($title, $description, $text) = map { _req_str($a->{$_}) } qw(title description body);
    return _err(422) unless defined $title && defined $description && defined $text;
    my $tags = $a->{tagList};
    $tags = [] unless defined $tags;
    return _err(422) unless ref $tags eq 'ARRAY';
    for my $t (@$tags) {
        return _err(422) unless defined _req_str($t);
    }

    my $id = eval {
        $DBH->begin_work;
        my $row = _row($SQL_INSERT_ARTICLE, $title, $uid, $title, $description, $text);
        die "no id\n" unless $row && $row->{id};
        if (@$tags) {
            _do($SQL_INSERT_TAGS, $tags);
            _do($SQL_INSERT_ARTICLE_TAGS, $row->{id}, $tags);
        }
        $DBH->commit;
        $row->{id};
    };
    if (my $err = $@) {
        eval { $DBH->rollback };
        return _err(422) if ($DBI::state // '') eq '23505';
        die $err;
    }

    my $row = _row($SQL_ARTICLE_BY_ID, $uid, $uid, $id);
    return _err(404) unless $row;
    return _respond_json(201, { article => _article_json($row, 1) });
}

sub _update_article {
    my ($uid, $slug, $body) = @_;
    my $owned = _row($SQL_ARTICLE_OWNED, $slug);
    return _err(404) unless $owned;
    return _err(403) unless $owned->{author_id} == $uid;

    my $data = eval { $JSON->decode($body) };
    return _err(422) unless ref $data eq 'HASH';
    my $a = $data->{article};
    return _err(422) unless ref $a eq 'HASH';
    my %f = map { $_ => _str_field($a->{$_}) } qw(title description body);
    return _err(422) if grep { defined && ($_ eq "\0invalid" || !length $_) } values %f;
    my ($title, $description, $text) = @f{qw(title description body)};

    _do($SQL_UPDATE_ARTICLE, $title, $description, $text, $title, $title, $owned->{id});
    my $row = _row($SQL_ARTICLE_BY_ID, $uid, $uid, $owned->{id});
    return _err(404) unless $row;
    return _respond_json(200, { article => _article_json($row, 1) });
}

sub _create_comment {
    my ($uid, $slug, $body) = @_;
    my $data = eval { $JSON->decode($body) };
    return _err(422) unless ref $data eq 'HASH';
    my $c = $data->{comment};
    return _err(422) unless ref $c eq 'HASH';
    my $text = _req_str($c->{body});
    return _err(422) unless defined $text;

    my $row = _row($SQL_INSERT_COMMENT, $uid, $text, $slug);
    return _err(404) unless $row;
    return _respond_json(201, { comment => _comment_json($row, 0) });
}

# ---------------------------------------------------------------- HTTP server

sub _listen_socket {
    my ($host, $port) = @_;
    socket(my $ls, PF_INET, SOCK_STREAM, 0) or die "socket: $!";
    setsockopt($ls, SOL_SOCKET, SO_REUSEADDR, pack('i', 1));
    if (defined &Socket::SO_REUSEPORT) {
        setsockopt($ls, SOL_SOCKET, Socket::SO_REUSEPORT(), pack('i', 1));
    }
    bind($ls, sockaddr_in($port, inet_aton($host))) or die "bind $host:$port: $!";
    listen($ls, 65535) or die "listen: $!";
    my $flags = fcntl($ls, F_GETFL, 0);
    fcntl($ls, F_SETFL, $flags | O_NONBLOCK) or die "fcntl listen: $!";
    return $ls;
}

sub _ev_flush {
    my ($c) = @_;
    my $s = $c->{s};
    while (length $c->{out}) {
        my $n = syswrite($s, $c->{out});
        if (!defined $n) {
            return 0 if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
            return -1;
        }
        return -1 if $n == 0;
        substr($c->{out}, 0, $n, '');
        $c->{last} = time;
    }
    return 1;
}

sub _ev_drop {
    my ($c, $conn) = @_;
    return unless $c->{open};
    $c->{open} = 0;
    if ($c->{w}) {
        $c->{w}->stop;
        $c->{w} = undef;
    }
    delete $conn->{$c->{fd}};
    close($c->{s});
}

sub _send {
    my ($c, $status, $body, $close) = @_;
    my $reason = $REASON{$status} // 'OK';
    my $head;
    if ($status == 204) {
        $head = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: "
          . ($close ? 'close' : 'keep-alive') . "\r\n\r\n";
    } else {
        $head = "HTTP/1.1 $status $reason\r\nContent-Type: application/json\r\nContent-Length: "
          . length($body) . "\r\nConnection: " . ($close ? 'close' : 'keep-alive') . "\r\n\r\n";
    }
    $c->{out} .= $head;
    $c->{out} .= $body if $status != 204;
}

sub _process {
    my ($c) = @_;
    while (1) {
        my $i = index($c->{in}, "\r\n\r\n");
        last if $i < 0;
        last if $i > $MAX_HEAD;
        my $head = substr($c->{in}, 0, $i);
        my @lines = split /\r\n/, $head, -1;
        my $reqline = shift @lines;
        my ($method, $target, $proto) = $reqline =~ m{^(\S+)\s+(\S+)\s+HTTP/1\.[01]$};
        if (!$method) {
            _send($c, 400, $ERR_BODY{400}, 1);
            $c->{close_after} = 1;
            last;
        }
        my %h;
        for my $line (@lines) {
            next unless $line =~ /^([^:]+):\s*(.*?)\s*$/;
            my $k = lc $1;
            next unless $k eq 'content-length' || $k eq 'connection' || $k eq 'authorization';
            $h{$k} = $2;
        }
        my $cl = $h{'content-length'};
        $cl = 0 unless defined $cl;
        if ($cl !~ /^\d{1,9}$/ || $cl > $MAX_BODY) {
            _send($c, 400, $ERR_BODY{400}, 1);
            $c->{close_after} = 1;
            last;
        }
        my $total = $i + 4 + $cl;
        last if length($c->{in}) < $total;

        my $body = $cl ? substr($c->{in}, $i + 4, $cl) : '';
        substr($c->{in}, 0, $total, '');

        my ($path, $qs) = split /\?/, $target, 2;
        my $query = _parse_query($qs);
        my $close = (($h{connection} // '') =~ /\bclose\b/i) || ($proto eq 'HTTP/1.0' && ($h{connection} // '') !~ /\bkeep-alive\b/i);

        my ($status, $out);
        my $ok = eval {
            ($status, $out) = _handle($method, $path, $query, \%h, $body);
            1;
        };
        if (!$ok) {
            warn "handler error: $@";
            ($status, $out) = (500, $ERR_BODY{500});
            $close = 1;
        }
        _send($c, $status, $out, $close);
        if ($close) {
            $c->{close_after} = 1;
            last;
        }
        last if length($c->{in}) > $MAX_BODY;
    }

    return;
}

sub _ev_event {
    my ($c, $conn, $revents) = @_;
    return unless $c->{open};
    if ($revents & EV::ERROR) {
        _ev_drop($c, $conn);
        return;
    }
    if ($revents & EV::WRITE) {
        my $r = _ev_flush($c);
        if ($r < 0 || ($c->{close_after} && !length $c->{out})) {
            _ev_drop($c, $conn);
            return;
        }
        if ($c->{close_after}) {
            $c->{w}->set($c->{s}, EV::WRITE);
            return;
        }
        $c->{w}->set($c->{s}, length($c->{out}) ? EV::READ | EV::WRITE : EV::READ);
        return unless $revents & EV::READ;
    }
    if ($revents & EV::READ) {
        while (1) {
            my $got = sysread($c->{s}, my $buf, 65536);
            if (!defined $got) {
                if ($! == EINTR) { next; }
                last if $! == EAGAIN || $! == EWOULDBLOCK;
                _ev_drop($c, $conn);
                return;
            }
            if ($got == 0) {
                $c->{close_after} = 1;
                last;
            }
            $c->{last} = time;
            $c->{in} .= $buf;
            _process($c);
            last if $c->{close_after};
        }
        my $r = _ev_flush($c);
        if ($r < 0 || ($c->{close_after} && !length $c->{out})) {
            _ev_drop($c, $conn);
            return;
        }
        if ($c->{close_after}) {
            $c->{w}->set($c->{s}, EV::WRITE);
            return;
        }
        $c->{w}->set($c->{s}, length($c->{out}) ? EV::READ | EV::WRITE : EV::READ);
    }
}

sub _worker {
    my $host = $ENV{HOST} // '127.0.0.1';
    my $port = $ENV{PORT} // 3000;
    _db_connect();
    my $ls = _listen_socket($host, $port);
    my %conn;

    $SIG{PIPE} = 'IGNORE';
    $SIG{TERM} = sub { exit 0 };
    $SIG{INT}  = sub { exit 0 };

    my $accept = EV::io($ls, EV::READ, sub {
        for (1 .. 128) {
            my $paddr = accept(my $cs, $ls);
            last unless $paddr;
            my $flags = fcntl($cs, F_GETFL, 0);
            fcntl($cs, F_SETFL, $flags | O_NONBLOCK);
            setsockopt($cs, IPPROTO_TCP, TCP_NODELAY, pack('i', 1));
            my $c = { s => $cs, fd => fileno($cs), in => '', out => '', last => time, close_after => 0, open => 1 };
            $conn{$c->{fd}} = $c;
            $c->{w} = EV::io($cs, EV::READ, sub { _ev_event($c, \%conn, $_[1]) });
        }
    });

    my $timer = EV::timer(1, 1, sub {
        my $now = time;
        for my $fd (keys %conn) {
            my $c = $conn{$fd};
            _ev_drop($c, \%conn) if $now - $c->{last} > $IDLE_SECS;
        }
    });

    EV::run;
}

sub _nproc {
    my $n = 0;
    if (open my $fh, '<', '/proc/cpuinfo') {
        $n++ while <$fh> =~ /^processor\s*:/;
    }
    return $n || 1;
}

# ---------------------------------------------------------------- main

my $workers = $ENV{WORKERS};
if (!defined $workers) {
    $workers = 95;
    my $n = _nproc();
    $workers = $n if $n < $workers && $n < 8;
}

$SIG{PIPE} = 'IGNORE';

my @pids;
$SIG{TERM} = sub {
    kill 'TERM', @pids;
    for my $p (@pids) { waitpid($p, 0) }
    exit 0;
};
$SIG{INT} = $SIG{TERM};

for (1 .. $workers) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        $SIG{TERM} = sub { exit 0 };
        $SIG{INT}  = sub { exit 0 };
        $SIG{PIPE} = 'IGNORE';
        eval { _worker() };
        warn "worker died: $@" if $@;
        exit 1;
    }
    push @pids, $pid;
}

while (1) {
    my $pid = waitpid(-1, 0);
    last if $pid < 0;
}
