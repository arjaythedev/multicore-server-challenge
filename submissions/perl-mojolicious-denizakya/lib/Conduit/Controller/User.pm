package Conduit::Controller::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Conduit ();

sub register ($self) {
  my $body = $self->req->json // {};
  return $self->exception_422 unless ref $body eq 'HASH';
  my $u = $body->{user} // {};
  return $self->exception_422 unless ref $u eq 'HASH';
  my ($username, $email, $password)
    = map { Conduit::_req_str($u->{$_}) } qw(username email password);
  return $self->exception_422 unless $username && $email && $password;
  return $self->exception_422 unless Conduit::_password_ok($password);

  my $row = eval {
    $self->db->selectrow_hashref(
      'INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)'
      . ' RETURNING id, username, email, bio, image',
      {Slice => {}}, $username, $email, Conduit::_bcrypt_hash($password),
    );
  };
  if (my $err = $@) {
    return $self->exception_422 if $DBI::state eq '23505';
    die $err;
  }
  return $self->render(json => {user => Conduit::_user_json($row, Conduit::_new_token($row->{id}))},
    status => 201);
}

sub login ($self) {
  my $body = $self->req->json // {};
  return $self->exception_422 unless ref $body eq 'HASH';
  my $u = $body->{user} // {};
  return $self->exception_422 unless ref $u eq 'HASH';
  my ($email, $password) = map { Conduit::_req_str($u->{$_}) } qw(email password);
  return $self->exception_422 unless $email && $password;

  my $row = $self->db->selectrow_hashref(
    'SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ?',
    {Slice => {}}, $email,
  );
  return $self->render(json => {errors => {body => ['invalid credentials']}}, status => 401)
    unless $row && Conduit::_bcrypt_check($password, $row->{password_hash});
  return $self->render(json => {user => Conduit::_user_json($row, Conduit::_new_token($row->{id}))});
}

sub get ($self) {
  my ($uid, $token) = Conduit::_auth_required($self) or return;
  my $row = $self->db->selectrow_hashref(
    'SELECT id, username, email, bio, image FROM users WHERE id = ?', {Slice => {}}, $uid,
  );
  return $self->render(json => {errors => {body => ['not found']}}, status => 401) unless $row;
  return $self->render(json => {user => Conduit::_user_json($row, $token)});
}

sub update ($self) {
  my ($uid, $token) = Conduit::_auth_required($self) or return;
  my $body = $self->req->json // {};
  return $self->exception_422 unless ref $body eq 'HASH';
  my $u = $body->{user};
  return $self->exception_422 unless ref $u eq 'HASH';

  # Absent or null leaves a field unchanged; a present value must be a string (empty allowed
  # for bio/image), and a non-empty one for the identity fields.
  my %f = map { $_ => Conduit::_str_field($u->{$_}) } qw(email username password bio image);
  return $self->exception_422 if grep { defined && $_ eq "\0invalid" } values %f;
  return $self->exception_422
    if defined($f{email}) && !length($f{email}) || defined($f{username}) && !length($f{username})
    || defined($f{password}) && !length($f{password})
    || defined($f{password}) && !Conduit::_password_ok($f{password});
  my ($email, $username, $password, $bio, $image) = @f{qw(email username password bio image)};
  $password = Conduit::_bcrypt_hash($password) if defined $password;

  my $row = eval {
    $self->db->selectrow_hashref(
      'UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),'
      . ' password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)'
      . ' WHERE id = ? RETURNING id, username, email, bio, image',
      {Slice => {}}, $email, $username, $password, $bio, $image, $uid,
    );
  };
  if (my $err = $@) {
    return $self->exception_422 if $DBI::state eq '23505';
    die $err;
  }
  return $self->render(json => {errors => {body => ['not found']}}, status => 401) unless $row;
  return $self->render(json => {user => Conduit::_user_json($row, $token)});
}

sub profile ($self) {
  my ($viewer) = Conduit::_auth_optional($self) or return;
  my $row = $self->db->selectrow_hashref(
    'SELECT u.id, u.username, u.bio, u.image,'
    . ' EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = u.id) AS following'
    . ' FROM users u WHERE u.username = ?',
    {Slice => {}}, $viewer, $self->param('username'),
  );
  return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
  return $self->render(json => {profile => Conduit::_profile_json($row, delete $row->{following})});
}

{
  my $lookup = 'SELECT id, username, bio, image FROM users WHERE username = ?';

  sub follow ($self) {
    my ($uid) = Conduit::_auth_required($self) or return;
    my $row = $self->db->selectrow_hashref($lookup, {Slice => {}}, $self->param('username'));
    return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
    $self->db->do('INSERT INTO follows (follower_id, followee_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
      {}, $uid, $row->{id});
    return $self->render(json => {profile => Conduit::_profile_json($row, 1)});
  }

  sub unfollow ($self) {
    my ($uid) = Conduit::_auth_required($self) or return;
    my $row = $self->db->selectrow_hashref($lookup, {Slice => {}}, $self->param('username'));
    return $self->render(json => {errors => {body => ['not found']}}, status => 404) unless $row;
    $self->db->do('DELETE FROM follows WHERE follower_id = ? AND followee_id = ?', {}, $uid, $row->{id});
    return $self->render(json => {profile => Conduit::_profile_json($row, 0)});
  }
}

1;
