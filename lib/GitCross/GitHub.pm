package GitCross::GitHub;

# Open pull requests of a GitHub repository, listed with the gh CLI

use strict;
use warnings;
use JSON::PP;

my @FIELDS = qw (number title author url baseRefName headRefName headRefOid
                 isDraft updatedAt);

sub list_open_prs
{
  my ($repo) = @_;
  my @cmd = ('gh', 'pr', 'list', '--repo', $repo, '--state', 'open',
             '--limit', '1000', '--json', join (',', @FIELDS));
  open (my $fh, '-|', @cmd) or die "Cannot run gh: $!\n";
  my $json = do { local $/; <$fh> };
  close ($fh) or die "gh pr list failed for $repo\n";

  return [ map
    {
      +{ number => $_->{number}, title => $_->{title},
        author => $_->{author}{login} // '', url => $_->{url},
        base => $_->{baseRefName}, head => $_->{headRefName},
        sha => $_->{headRefOid}, draft => $_->{isDraft} ? 1 : 0,
        updated => $_->{updatedAt} }
    } @{ decode_json ($json) } ];
}

1;
