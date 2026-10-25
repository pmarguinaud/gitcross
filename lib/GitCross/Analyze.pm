package GitCross::Analyze;

# Conflict analysis: each PR against its base branch, then each pair of PRs
# sharing the same base branch and touching at least one common file.
#
# A pair (A, B) is checked by simulating "A merged into base" (a temporary
# commit, never pushed) and merging B on top of it. When A conflicts with
# the base, B is merged first instead; when both conflict with the base,
# A and B are merged directly and the result is flagged as approximate.

use strict;
use warnings;
use JSON::PP;

our $CACHE_VERSION = 1;

sub new
{
  my ($class, %args) = @_;
  my $self = bless { git => $args{git}, cache_file => $args{cache_file},
                     progress => $args{progress} // sub {}, sim => {} }, $class;
  $self->_load_cache ();
  return $self;
}

sub _load_cache
{
  my $self = shift;
  $self->{cache} = {};
  my $f = $self->{cache_file};
  return unless ($f && -f $f);
  my $c = eval
    {
      open (my $fh, '<', $f) or die;
      local $/;
      decode_json (<$fh>);
    };
  $self->{cache} = $c->{entries}
    if ($c && ($c->{version} // 0) == $CACHE_VERSION);
}

sub _save_cache
{
  my $self = shift;
  my $f = $self->{cache_file} or return;
  open (my $fh, '>', "$f.tmp") or die "Cannot write $f.tmp: $!\n";
  print $fh JSON::PP->new->utf8->canonical->encode (
    { version => $CACHE_VERSION, entries => $self->{used} });
  close ($fh);
  rename ("$f.tmp", $f) or die "Cannot write $f: $!\n";
}

# Return the cached value for $key, or compute and remember it.
# Only entries used by this run are saved, so the cache does not grow.
sub _cached
{
  my ($self, $key, $code) = @_;
  my $v = $self->{cache}{$key} // $code->();
  $self->{used}{$key} = $v;
  return $v;
}

# Convert a merge_tree result into a sorted list of { path, type }
sub _conflicted_files
{
  my $mt = shift;
  my %type;
  for my $c (@{ $mt->{conflicts} })
    {
      for my $p (@{ $c->{paths} })
        {
          $type{$p} //= $c->{type};
        }
    }
  return [ map { +{ path => $_, type => $type{$_} // 'unknown' } }
           sort @{ $mt->{files} } ];
}

# Commit "base + PR merged", memoized for this run
sub _simulated
{
  my ($self, $base_sha, $pr) = @_;
  return $self->{sim}{"$base_sha:$pr->{sha}"} //= do
    {
      my $mt = $self->{git}->merge_tree ($base_sha, $pr->{sha});
      $self->{git}->commit_tree ($mt->{tree}, $base_sha, $pr->{sha});
    };
}

# $prs: list of { number, base, sha, ... } whose sha is present in the
# repository, as well as refs/heads/<base>.
# Returns { prs => { number => pr + results }, bases => [ ... ], hot_files => [ ... ] }
sub run
{
  my ($self, $prs) = @_;
  my $git = $self->{git};
  my (%by_base, %pr);

  for my $p (sort { $a->{number} <=> $b->{number} } @$prs)
    {
      $pr{$p->{number}} = { %$p };
      push @{ $by_base{$p->{base}} }, $pr{$p->{number}};
    }

  my @bases;
  my $n = 0;
  for my $base (sort { @{ $by_base{$b} } <=> @{ $by_base{$a} } || $a cmp $b } keys %by_base)
    {
      my $base_sha = $git->rev_parse ("refs/heads/$base")
        or die "Base branch $base not found in the mirror\n";
      my $list = $by_base{$base};

      for my $p (@$list)
        {
          $n++;
          $self->{progress}->(sprintf ("[%d/%d] #%d vs %s", $n, scalar (@$prs), $p->{number}, $base));
          my $r = $self->_cached ("base:$base_sha:$p->{sha}", sub
            {
              my $mt = $git->merge_tree ($base_sha, $p->{sha});
              return { clean   => $mt->{clean},
                files   => _conflicted_files ($mt),
                changed => $git->changed_files ($base_sha, $p->{sha}),
                behind  => $git->behind ($base_sha, $p->{sha}) + 0 };
            });
          $p->{base_status}    = $r->{clean} ? 'clean' : 'conflict';
          $p->{base_conflicts} = $r->{files};
          $p->{changed}        = $r->{changed};
          $p->{behind}         = $r->{behind};
        }

      my %pairs;
      for my $i (0 .. $#$list)
        {
          my $A = $list->[$i];
          my %changed = map { ($_ => 1) } @{ $A->{changed} };
          for my $j ($i + 1 .. $#$list)
            {
              my $B = $list->[$j];
              my @common = grep { $changed{$_} } @{ $B->{changed} };
              next unless (@common);
              $self->{progress}->(sprintf ("pair #%d / #%d (%s)", $A->{number}, $B->{number}, $base));
              my $r = $self->_cached ("pair:$base_sha:$A->{sha}:$B->{sha}",
                                      sub { $self->_pair ($base_sha, $A, $B) });
              $pairs{"$A->{number},$B->{number}"} =
                { a => $A->{number}, b => $B->{number}, common => [sort @common], %$r };
            }
        }

      push @bases, { name => $base, sha => $base_sha,
                     prs => [ map { $_->{number} } @$list ], pairs => \%pairs,
                     _summarize ($list, \%pairs) };
    }

  $self->_save_cache ();
  return { prs => \%pr, bases => \@bases, hot_files => _hot_files (\%pr, \@bases) };
}

sub _pair
{
  my ($self, $base_sha, $A, $B) = @_;
  my $git = $self->{git};
  my ($first, $second) = $A->{base_status} eq 'clean' ? ($A, $B)
                       : $B->{base_status} eq 'clean' ? ($B, $A)
                       : ();
  my ($mt, $note);
  my %ignore;
  if ($first)
    {
      $mt = $git->merge_tree ($self->_simulated ($base_sha, $first), $second->{sha});
      if ($second->{base_status} ne 'clean')
        {
          # Ignore files that already conflict between $second and the base
          %ignore = map { ($_->{path} => 1) } @{ $second->{base_conflicts} };
          $note = "approximate: #$second->{number} conflicts with the base";
        }
    }
  else
    {
      $mt = $git->merge_tree ($A->{sha}, $B->{sha});
      $note = 'approximate: both PRs conflict with the base, merged directly';
    }
  my @files = grep { ! $ignore{$_->{path}} } @{ _conflicted_files ($mt) };
  return { status => @files ? 'conflict' : 'overlap', files => \@files,
           ($note ? (note => $note) : ()) };
}

# PRs that can be merged now (clean against the base and with every other PR),
# and clusters of PRs linked by conflicts (connected components)
sub _summarize
{
  my ($list, $pairs) = @_;
  my %adj;
  for my $p (values %$pairs)
    {
      next unless ($p->{status} eq 'conflict');
      push @{ $adj{$p->{a}} }, $p->{b};
      push @{ $adj{$p->{b}} }, $p->{a};
    }

  my @ready = map { $_->{number} }
              grep { $_->{base_status} eq 'clean' && ! $adj{$_->{number}} } @$list;

  my (%seen, @clusters);
  for my $start (sort { $a <=> $b } keys %adj)
    {
      next if ($seen{$start}++);
      my @todo = ($start);
      my @c;
      while (defined (my $x = shift (@todo)))
        {
          push @c, $x;
          push @todo, grep { ! $seen{$_}++ } @{ $adj{$x} };
        }
      push @clusters, [sort { $a <=> $b } @c];
    }

  # Problem counters of each PR, and PRs ordered from the least to the most
  # problematic: number of conflicts (base + PRs), then conflicting files,
  # then overlaps without conflict
  for my $p (@$list)
    {
      $p->{problems} = { base => $p->{base_status} eq 'clean' ? 0 : 1,
                         prs => 0, files => scalar (@{ $p->{base_conflicts} }), overlaps => 0 };
    }
  my %pr = map { ($_->{number} => $_) } @$list;
  for my $p (values %$pairs)
    {
      for my $n ($p->{a}, $p->{b})
        {
          my $c = $pr{$n}{problems};
          if ($p->{status} eq 'conflict')
            {
              $c->{prs}++;
              $c->{files} += @{ $p->{files} };
            }
          else
            {
              $c->{overlaps}++;
            }
        }
    }
  my $key = sub { my $c = $_[0]{problems}; ($c->{base} + $c->{prs}, $c->{files}, $c->{overlaps}) };
  my @by_problem = map { $_->{number} } sort
    {
      my @x = $key->($a);
      my @y = $key->($b);
      $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] || $a->{number} <=> $b->{number}
    } @$list;

  return (ready => \@ready, clusters => \@clusters, by_problem => \@by_problem);
}

# Short text describing the problem counters of a PR
sub problems_text
{
  my $c = shift->{problems};
  my @t;
  push @t, 'base' if ($c->{base});
  push @t, "$c->{prs} PR" . ($c->{prs} > 1 ? 's' : '') if ($c->{prs});
  push @t, "$c->{files} file" . ($c->{files} > 1 ? 's' : '') if ($c->{files});
  push @t, "$c->{overlaps} overlap" . ($c->{overlaps} > 1 ? 's' : '') if ($c->{overlaps});
  return @t ? join (', ', @t) : 'none';
}

# PR numbers of a base branch, in the order requested for the reports
sub matrix_order
{
  my ($bb, $sort) = @_;
  return @{ ($sort // 'problem') eq 'number' ? $bb->{prs} : $bb->{by_problem} };
}

# Files involved in conflicts, most frequent first
sub _hot_files
{
  my ($pr, $bases) = @_;
  my %h;
  for my $p (values %$pr)
    {
      push @{ $h{$_->{path}}{base} }, $p->{number} for (@{ $p->{base_conflicts} });
    }
  for my $b (@$bases)
    {
      for my $p (values %{ $b->{pairs} })
        {
          push @{ $h{$_->{path}}{pairs} }, "$p->{a}/$p->{b}" for (@{ $p->{files} });
        }
    }
  my @hot = map
    {
      my $base  = [sort { $a <=> $b } @{ $h{$_}{base} // [] }];
      my $pairs = [sort @{ $h{$_}{pairs} // [] }];
      +{ path => $_, base => $base, pairs => $pairs, count => @$base + @$pairs };
    } keys %h;
  return [ sort { $b->{count} <=> $a->{count} || $a->{path} cmp $b->{path} } @hot ];
}

1;
