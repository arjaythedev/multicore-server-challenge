package Conduit::Controller::Article;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Conduit ();

my $ARTICLE_LIST_SELECT = <<'SQL';
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
SQL

my $ARTICLE_FULL_SELECT = $ARTICLE_LIST_SELECT =~ s/a\.created_at/a.body, a.created_at/r;
my $ORDER_PAGE          = ' ORDER BY a.id DESC LIMIT ? OFFSET ?';
my $SLUGIFY             = q{trim(both '-' from lower(regexp_replace(?, '[^A-Za-z0-9]+', '-', 'g')))};

sub _render_list ($self, $rows, $count) {
  my @articles = map { Conduit::_article_json($_, 0) } @$rows;
  return $self->render(json => {articles => \@articles, articlesCount => 0 + $count});
}

sub list ($self) {
  my ($viewer) = Conduit::_auth_optional($self) or return;
  my ($limit, $offset) = Conduit::_page($self) or return $self->exception_422;
  my $dbh = $self->db;
  my $first = sub {
    my $v = $self->every_param($_[0]);
    return $v && @$v ? $v->[0] : undef;
  };
  my ($tag, $author, $favorited) = map {
    my $v = $first->($_);
    (defined $v && length $v) ? $v : undef;
  } qw(tag author favorited);

  my $filter = defined $tag ? 'tag' : defined $author ? 'author' : defined $favorited ? 'favorited' : undef;
  my ($rows, $count);

  if (!$filter) {
    $rows = $dbh->selectall_arrayref($ARTICLE_LIST_SELECT . $ORDER_PAGE, {Slice => {}},
      $viewer, $viewer, $limit, $offset);
    ($count) = $dbh->selectrow_array('SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s');
  }
  elsif ($filter eq 'tag') {
    $rows = $dbh->selectall_arrayref(
      $ARTICLE_LIST_SELECT
      . ' WHERE a.id IN (SELECT at.article_id FROM article_tags at'
      . ' WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?)'
      . ' ORDER BY at.article_id DESC LIMIT ? OFFSET ?) ORDER BY a.id DESC',
      {Slice => {}}, $viewer, $viewer, $tag, $limit, $offset);
    ($count) = $dbh->selectrow_array(
      'SELECT count(*) FROM (SELECT 1 FROM article_tags at'
      . ' WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?) LIMIT 1000) s', {}, $tag);
  }
  elsif ($filter eq 'author') {
    $rows = $dbh->selectall_arrayref(
      $ARTICLE_LIST_SELECT . ' WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = ?)'
      . $ORDER_PAGE,
      {Slice => {}}, $viewer, $viewer, $author, $limit, $offset);
    ($count) = $dbh->selectrow_array(
      'SELECT count(*) FROM (SELECT 1 FROM articles a'
      . ' WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = ?) LIMIT 1000) s', {}, $author);
  }
  else {    # favorited
    $rows = $dbh->selectall_arrayref(
      $ARTICLE_LIST_SELECT
      . ' WHERE a.id IN (SELECT f.article_id FROM favorites f'
      . ' WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?)'
      . ' ORDER BY f.article_id DESC LIMIT ? OFFSET ?) ORDER BY a.id DESC',
      {Slice => {}}, $viewer, $viewer, $favorited, $limit, $offset);
    ($count) = $dbh->selectrow_array(
      'SELECT count(*) FROM (SELECT 1 FROM favorites f'
      . ' WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?) LIMIT 1000) s',
      {}, $favorited);
  }

  return $self->_render_list($rows, $count);
}

sub feed ($self) {
  my ($viewer) = Conduit::_auth_required($self) or return;
  my ($limit, $offset) = Conduit::_page($self) or return $self->exception_422;
  my $dbh = $self->db;
  my $rows = $dbh->selectall_arrayref(
    $ARTICLE_LIST_SELECT
    . ' WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL'
    . '   (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id'
    . '    ORDER BY a2.id DESC LIMIT (?::int + ?::int)) x'
    . '  WHERE fo.follower_id = ? ORDER BY x.id DESC LIMIT ? OFFSET ?) ORDER BY a.id DESC',
    {Slice => {}}, $viewer, $viewer, $limit, $offset, $viewer, $limit, $offset);
  my ($count) = $dbh->selectrow_array(
    'SELECT count(*) FROM (SELECT 1 FROM articles a'
    . ' WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ?)'
    . ' LIMIT 1000) s', {}, $viewer);
  return $self->_render_list($rows, $count);
}

sub get ($self) {
  my ($viewer) = Conduit::_auth_optional($self) or return;
  my $row = $self->db->selectrow_hashref(
    $ARTICLE_FULL_SELECT . ' WHERE a.slug = ?', {Slice => {}}, $viewer, $viewer, $self->param('slug'));
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
  return $self->render(json => {article => Conduit::_article_json($row, 1)});
}

sub create ($self) {
  my ($uid) = Conduit::_auth_required($self) or return;
  my $body = $self->req->json // {};
  return $self->exception_422 unless ref $body eq 'HASH';
  my $a = $body->{article} // {};
  return $self->exception_422 unless ref $a eq 'HASH';
  my ($title, $description, $text) = map { Conduit::_req_str($a->{$_}) } qw(title description body);
  return $self->exception_422 unless $title && $description && $text;

  my $tag_list = $a->{tagList} // [];
  return $self->exception_422 if ref $tag_list ne 'ARRAY';
  return $self->exception_422
    if grep { !Conduit::_req_str($_) } @$tag_list;

  my $dbh = $self->db;
  my $id = eval {
    $dbh->begin_work;
    my ($id) = $dbh->selectrow_array(
      'INSERT INTO articles (id, slug, author_id, title, description, body)'
      . " SELECT n.id, $SLUGIFY || '-' || n.id, ?, ?, ?, ?"
      . ' FROM (SELECT nextval(pg_get_serial_sequence(\'articles\', \'id\')) AS id) n RETURNING id',
      {}, $title, $uid, $title, $description, $text);
    die 'insert returned no id' unless $id;
    if (@$tag_list) {
      $dbh->do('INSERT INTO tags (name) SELECT DISTINCT unnest(?::text[]) ON CONFLICT (name) DO NOTHING',
        {}, \@$tag_list);
      $dbh->do('INSERT INTO article_tags (article_id, tag_id) SELECT ?, t.id FROM tags t WHERE t.name = ANY(?::text[])',
        {}, $id, \@$tag_list);
    }
    $dbh->commit;
    $id;
  };
  if (my $err = $@) {
    eval { $dbh->rollback };
    return $self->exception_422 if $DBI::state eq '23505';
    die $err;
  }

  my $row = $self->db->selectrow_hashref(
    $ARTICLE_FULL_SELECT . ' WHERE a.id = ?', {Slice => {}}, $uid, $uid, $id);
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
  return $self->render(json => {article => Conduit::_article_json($row, 1)}, status => 201);
}

sub _owned_article ($self) {
  my ($uid) = Conduit::_auth_required($self) or return;
  my $row = $self->db->selectrow_hashref(
    'SELECT id, author_id FROM articles WHERE slug = ?', {Slice => {}}, $self->param('slug'));
  if (!$row) {
    $self->render(json => {errors => {body => ['not found']}}, status => 404);
    return;
  }
  if ($row->{author_id} != $uid) {
    $self->render(json => {errors => {body => ['forbidden']}}, status => 403);
    return;
  }
  return $row;
}

sub update ($self) {
  my $owned = $self->_owned_article or return;
  my $body = $self->req->json // {};
  return $self->exception_422 unless ref $body eq 'HASH';
  my $a = $body->{article};
  return $self->exception_422 unless ref $a eq 'HASH';
  my %f = map { $_ => Conduit::_str_field($a->{$_}) } qw(title description body);
  return $self->exception_422
    if grep { defined && ($_ eq "\0invalid" || !length $_) } values %f;
  my ($title, $description, $text) = @f{qw(title description body)};

  my ($uid) = Conduit::_auth_required($self);
  $self->db->do(
    'UPDATE articles SET title = COALESCE(?, title), description = COALESCE(?, description),'
    . ' body = COALESCE(?, body),'
    . " slug = CASE WHEN ?::text IS NULL THEN slug ELSE $SLUGIFY || '-' || id END,"
    . ' updated_at = now()'
    . ' WHERE id = ?',
    {}, $title, $description, $text, $title, $title, $owned->{id});
  my $row = $self->db->selectrow_hashref(
    $ARTICLE_FULL_SELECT . ' WHERE a.id = ?', {Slice => {}}, $uid, $uid, $owned->{id});
  return $self->render(json => {article => Conduit::_article_json($row, 1)});
}

sub delete ($self) {
  my $owned = $self->_owned_article or return;
  $self->db->do('DELETE FROM articles WHERE id = ?', {}, $owned->{id});
  return $self->render(data => '', status => 204);
}

{
  my $lookup = 'SELECT id FROM articles WHERE slug = ?';

  sub favorite ($self) {
    my ($uid) = Conduit::_auth_required($self) or return;
    my $row = $self->db->selectrow_hashref($lookup, {Slice => {}}, $self->param('slug'));
    return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
    $self->db->do('INSERT INTO favorites (user_id, article_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
      {}, $uid, $row->{id});
    return $self->_full($uid, $row->{id});
  }

  sub unfavorite ($self) {
    my ($uid) = Conduit::_auth_required($self) or return;
    my $row = $self->db->selectrow_hashref($lookup, {Slice => {}}, $self->param('slug'));
    return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
    $self->db->do('DELETE FROM favorites WHERE user_id = ? AND article_id = ?', {}, $uid, $row->{id});
    return $self->_full($uid, $row->{id});
  }
}

sub _full ($self, $uid, $id) {
  my $row = $self->db->selectrow_hashref(
    $ARTICLE_FULL_SELECT . ' WHERE a.id = ?', {Slice => {}}, $uid, $uid, $id);
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
  return $self->render(json => {article => Conduit::_article_json($row, 1)});
}

1;
