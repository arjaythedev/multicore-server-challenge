package Conduit::Controller::Tag;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub list ($self) {
  my $tags = $self->db->selectcol_arrayref('SELECT name FROM tags ORDER BY name');
  return $self->render(json => {tags => $tags});
}

1;
