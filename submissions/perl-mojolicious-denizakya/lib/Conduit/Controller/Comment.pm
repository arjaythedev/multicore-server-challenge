package Conduit::Controller::Comment;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Conduit ();

sub list ($self) {
  my ($viewer) = Conduit::_auth_optional($self) or return;
  my $dbh = $self->db;
  my $article = $dbh->selectrow_hashref(
    'SELECT id FROM articles WHERE slug = ?', {Slice => {}}, $self->param('slug'));
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $article;

  my $rows = $dbh->selectall_arrayref(
    'SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,'
    . ' EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = c.author_id) AS following'
    . ' FROM comments c JOIN users u ON u.id = c.author_id'
    . ' WHERE c.article_id = ?'
    . ' ORDER BY c.created_at DESC, c.id DESC LIMIT 100',
    {Slice => {}}, $viewer, $article->{id});
  my @comments = map { Conduit::_comment_json($_, delete $_->{following}) } @$rows;
  return $self->render(json => {comments => \@comments});
}

sub create ($self) {
  my ($uid) = Conduit::_auth_required($self) or return;
  my $body = $self->req->json // {};
  return $self->exception_422 unless ref $body eq 'HASH';
  my $c = $body->{comment} // {};
  return $self->exception_422 unless ref $c eq 'HASH';
  my $text = Conduit::_req_str($c->{body});
  return $self->exception_422 unless $text;

  my $dbh = $self->db;
  my $article = $dbh->selectrow_hashref(
    'SELECT id FROM articles WHERE slug = ?', {Slice => {}}, $self->param('slug'));
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $article;

  my $row = $dbh->selectrow_hashref(
    'WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES (?, ?, ?)'
    . ' RETURNING id, body, created_at, updated_at, author_id)'
    . ' SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image'
    . ' FROM c JOIN users u ON u.id = c.author_id',
    {Slice => {}}, $article->{id}, $uid, $text);
  return $self->render(json => {comment => Conduit::_comment_json($row, 0)}, status => 201);
}

sub delete ($self) {
  my ($uid) = Conduit::_auth_required($self) or return;
  my $row = $self->db->selectrow_hashref(
    'SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id'
    . ' WHERE c.id = ? AND a.slug = ?',
    {Slice => {}}, $self->param('id'), $self->param('slug'));
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
  return $self->render(json => {errors => {body => ['forbidden']}}, status => 403)
    if $row->{author_id} != $uid;
  $self->db->do('DELETE FROM comments WHERE id = ?', {}, $self->param('id'));
  return $self->render(data => '', status => 204);
}

1;
