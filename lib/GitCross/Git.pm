package GitCross::Git;

# Thin wrapper around the git command line, operating on one repository
# (normally a bare mirror). Commands are run without a shell.

use strict;
use warnings;
use Encode qw (decode);

sub new
{
  my ($class, %args) = @_;
  my $self = bless { dir => $args{dir}, verbose => $args{verbose} // 0 }, $class;
  return $self;
}

sub dir { $_[0]{dir} }

# Run git; return (exit status, stdout). Die if the status is above $max_ok.
sub run
{
  my ($self, $max_ok, @args) = @_;
  my @cmd = ('git', '-C', $self->{dir}, @args);
  print STDERR "+ @cmd\n" if ($self->{verbose} > 1);
  local $ENV{LC_ALL} = 'C';
  open (my $fh, '-|', @cmd) or die "Cannot run git: $!\n";
  binmode ($fh);
  my $out = do { local $/; <$fh> } // '';
  close ($fh);
  my $status = $? >> 8;
  die "Command failed (status $status): @cmd\n" if (($? & 127) || $status > $max_ok);
  return ($status, $out);
}

sub out
{
  my ($self, @args) = @_;
  my (undef, $out) = $self->run (0, @args);
  $out =~ s/\s+\z//;
  return $out;
}

# Create a bare mirror with an 'origin' remote, unless it already exists
sub init_mirror
{
  my ($self, $url) = @_;
  return if (-d $self->{dir});
  system ('git', 'init', '-q', '--bare', $self->{dir}) == 0
    or die "Cannot create mirror $self->{dir}\n";
  $self->out ('remote', 'add', 'origin', $url);
}

sub fetch
{
  my ($self, @refspecs) = @_;
  my @cmd = ('git', '-C', $self->{dir}, 'fetch', '--no-tags', '--force',
             ($self->{verbose} ? () : '--quiet'), 'origin', @refspecs);
  system (@cmd) == 0 or die "git fetch failed\n";
}

sub rev_parse
{
  my ($self, $ref) = @_;
  my ($status, $out) = $self->run (128, 'rev-parse', '--verify', '--quiet', "$ref^{commit}");
  return undef if ($status);
  $out =~ s/\s+\z//;
  return $out;
}

sub merge_base
{
  my ($self, $a, $b) = @_;
  my ($status, $out) = $self->run (1, 'merge-base', $a, $b);
  return undef if ($status);
  $out =~ s/\s+\z//;
  return $out;
}

# Number of commits in $base not in $ref
sub behind
{
  my ($self, $base, $ref) = @_;
  return $self->out ('rev-list', '--count', "$ref..$base");
}

# Files changed by $ref since its merge-base with $base (renames are
# reported as delete + add, so both paths appear)
sub changed_files
{
  my ($self, $base, $ref) = @_;
  my $mb = $self->merge_base ($base, $ref) // return [];
  my (undef, $out) = $self->run (0, 'diff', '--name-only', '-z', '--no-renames', $mb, $ref);
  return [grep { length } split (m/\0/o, decode ("UTF-8", $out))];
}

# In-memory three-way merge. Returns
#   { clean => 0|1, tree => oid, files => [paths],
#     conflicts => [ { paths => [...], type => 'contents', message => '...' } ] }
sub merge_tree
{
  my ($self, $a, $b) = @_;
  my ($status, $out) = $self->run (1, 'merge-tree', '--write-tree', '--name-only',
                                   '--messages', '-z', $a, $b);
  $out = decode ("UTF-8", $out);
  my @f = split (m/\0/o, $out, -1);
  my $tree = shift (@f);
  my @files;
  while (@f && length ($f[0]))
    {
      push @files, shift (@f);
    }
  shift (@f);   # empty separator

  my @conflicts;
  while (@f > 2)
    {
      my $n = shift (@f);
      last unless ($n =~ m/^\d+$/o);
      my @paths = splice (@f, 0, $n);
      my ($type, $msg) = splice (@f, 0, 2);
      next unless ($type =~ m/^CONFLICT\s*\((.*)\)/o);
      my $kind = $1;
      $msg =~ s/\s+\z//;
      push @conflicts, { paths => \@paths, type => $kind, message => $msg };
    }

  return { clean => $status == 0 ? 1 : 0, tree => $tree, files => \@files,
           conflicts => \@conflicts };
}

sub commit_tree
{
  my ($self, $tree, @parents) = @_;
  local $ENV{GIT_AUTHOR_NAME}     = 'gitcross';
  local $ENV{GIT_AUTHOR_EMAIL}    = 'gitcross@localhost';
  local $ENV{GIT_COMMITTER_NAME}  = 'gitcross';
  local $ENV{GIT_COMMITTER_EMAIL} = 'gitcross@localhost';
  return $self->out ('commit-tree', $tree, (map { ('-p', $_) } @parents),
                     '-m', 'gitcross simulated merge');
}

1;
