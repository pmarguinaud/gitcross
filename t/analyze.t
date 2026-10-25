use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use Test::More;
use File::Temp qw (tempdir);
use GitCross::Git;
use GitCross::Analyze;
use GitCross::Report::HTML;
use GitCross::Report::FODS;

my $dir = tempdir (CLEANUP => 1);
my $repo = "$dir/repo";

local $ENV{GIT_AUTHOR_NAME}     = 't';
local $ENV{GIT_AUTHOR_EMAIL}    = 't@t';
local $ENV{GIT_COMMITTER_NAME}  = 't';
local $ENV{GIT_COMMITTER_EMAIL} = 't@t';

sub sh { system ('git', '-C', $repo, @_) == 0 or die "git @_ failed\n" }

sub put
{
  my ($file, @lines) = @_;
  open (my $fh, '>', "$repo/$file") or die;
  print $fh map { "$_\n" } @lines;
  close ($fh);
}

my @ten = map { "line $_" } 1 .. 10;

# Base branch 'develop'
mkdir ($repo);
sh ('init', '-q', '-b', 'develop');
put ('f.txt', @ten);
put ('g.txt', 'g');
put ('h.txt', 'h');
sh ('add', '.');
sh ('commit', '-qm', 'base');
sh ('branch', 'other');

# Creates refs/pr/N from develop's root commit, modifying files
my %sha;
sub pr
{
  my ($n, $from, %files) = @_;
  sh ('checkout', '-q', '-B', "w$n", $from);
  put ($_, @{ $files{$_} }) for (keys %files);
  sh ('commit', '-qam', "pr $n");
  sh ('update-ref', "refs/pr/$n", "w$n");
  $sha{$n} = `git -C $repo rev-parse w$n`;
  chomp ($sha{$n});
}

pr (1, 'develop', 'f.txt' => ['one',  @ten[1 .. 9]]);
pr (2, 'develop', 'f.txt' => ['ONE',  @ten[1 .. 9]]);              # conflicts with 1
pr (3, 'develop', 'f.txt' => [@ten[0 .. 8], 'ten']);               # same file, no conflict
pr (4, 'develop', 'g.txt' => ['g4']);                              # conflicts with base (below)
pr (5, 'develop', 'h.txt' => ['h5']);                              # independent
pr (6, 'develop', 'g.txt' => ['g6'], 'f.txt' => ['uno', @ten[1 .. 9]]);  # conflicts with base, 1 and 2
pr (7, 'other',   'f.txt' => ['seven', @ten[1 .. 9]]);             # other base

# develop moves on after the PRs were created
sh ('checkout', '-q', 'develop');
put ('g.txt', 'g-develop');
sh ('commit', '-qam', 'develop moves');

my $git = GitCross::Git->new (dir => $repo);
my @prs = map { { number => $_, base => $_ == 7 ? 'other' : 'develop', sha => $sha{$_},
                  title => "PR $_", author => 'me', url => "https://example.org/$_" } } 1 .. 7;

my $an = GitCross::Analyze->new (git => $git, cache_file => "$dir/cache.json");
my $res = $an->run (\@prs);
my $p = $res->{prs};

is ($p->{1}{base_status}, 'clean',    'PR 1 clean with base');
is ($p->{4}{base_status}, 'conflict', 'PR 4 conflicts with base');
is_deeply ([map { $_->{path} } @{ $p->{4}{base_conflicts} }], ['g.txt'], 'PR 4 conflicting file');
is ($p->{4}{base_conflicts}[0]{type}, 'contents', 'conflict type');
is ($p->{1}{behind}, 1, 'PR 1 is one commit behind');

my ($dev) = grep { $_->{name} eq 'develop' } @{ $res->{bases} };
is (scalar (@{ $res->{bases} }), 2, 'two base branches');
my $pairs = $dev->{pairs};
is ($pairs->{'1,2'}{status}, 'conflict', '1 / 2 conflict');
is_deeply ([map { $_->{path} } @{ $pairs->{'1,2'}{files} }], ['f.txt'], '1 / 2 file');
is ($pairs->{'1,3'}{status}, 'overlap', '1 / 3 overlap without conflict');
ok (! $pairs->{'1,5'}, '1 / 5 not tested (no common file)');
is_deeply ([map { $_->{path} } @{ $pairs->{'4,6'}{files} }], ['g.txt'], '4 / 6 conflict (both conflict with base, merged directly)');
is ($pairs->{'1,6'}{status}, 'conflict', '1 / 6 conflict (6 conflicts with base)');
like ($pairs->{'1,6'}{note}, qr/approximate/, '1 / 6 flagged approximate');
ok (! exists $pairs->{'1,7'}, 'PRs on different bases not compared');

is_deeply ($dev->{ready}, [3, 5], 'PRs 3 and 5 mergeable now');
is_deeply ([@{ $dev->{by_problem} }[0, 1]], [5, 3], 'least problematic first: 5 (none), 3 (overlaps only)');
is ($dev->{by_problem}[-1], 6, 'most problematic last: 6 (base + 3 PRs)');
is (GitCross::Analyze::problems_text ($p->{6}), 'base, 3 PRs, 4 files, 1 overlap', 'problems text');
is_deeply ($dev->{clusters}, [[1, 2, 4, 6]], 'conflict cluster');
is ($res->{hot_files}[0]{path}, 'f.txt', 'f.txt is the hottest file');

# Cache is reused: same results without running merges
my $an2 = GitCross::Analyze->new (git => $git, cache_file => "$dir/cache.json");
no warnings 'redefine';
my $calls = 0;
my $orig = \&GitCross::Git::merge_tree;
local *GitCross::Git::merge_tree = sub { $calls++; $orig->(@_) };
my $res2 = $an2->run (\@prs);
is ($calls, 0, 'second run fully cached');
is_deeply ($res2->{bases}, $res->{bases}, 'cached results identical');

# Reports are written
GitCross::Report::HTML::write ("$dir/r.html", $res, { repo => 'o/r', generated => 'now' });
GitCross::Report::FODS::write ("$dir/r.fods", $res, { repo => 'o/r', generated => 'now' });
ok (-s "$dir/r.html", 'HTML written');
ok (-s "$dir/r.fods", 'FODS written');
if (system ('xmllint --version >/dev/null 2>&1') == 0)
  {
    is (system ('xmllint', '--noout', "$dir/r.fods"), 0, 'FODS is well-formed XML');
  }

done_testing ();
