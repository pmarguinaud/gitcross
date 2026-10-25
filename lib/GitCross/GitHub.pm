package GitCross::GitHub;

# Open pull requests of a GitHub repository, listed with the gh CLI

use strict;
use warnings;
use JSON::PP;
use Digest::SHA qw (sha256_hex);
use Encode qw (encode);

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

# GitHub web pages anchor each file of a diff by the SHA-256 of its path
sub file_anchor
{
  my $path = shift;
  return '#diff-' . sha256_hex (encode ('UTF-8', $path));
}

# Direct difference between two commits, optionally at a given file
sub compare_url
{
  my ($repo, $sha_a, $sha_b, $path) = @_;
  return "https://github.com/$repo/compare/$sha_a..$sha_b" . (defined ($path) ? file_anchor ($path) : '');
}

# Changes of a PR (given by its URL) to a file
sub pr_file_url
{
  my ($pr_url, $path) = @_;
  return "$pr_url/files" . file_anchor ($path);
}

1;
