package GitCross::Report::HTML;

# Self-contained HTML report (no external resources)

use strict;
use warnings;
use GitCross::Analyze;
use GitCross::GitHub;

sub _e
{
  my $s = shift // '';
  $s =~ s/&/&amp;/go;
  $s =~ s/</&lt;/go;
  $s =~ s/>/&gt;/go;
  $s =~ s/"/&quot;/go;
  return $s;
}

my $CSS = <<'EOF';
:root { --fg:#1d232b; --bg:#ffffff; --mut:#5b6573; --line:#d6dbe1; --head:#f1f3f6;
        --ok:#c9ebcf; --ovl:#ffe2a8; --bad:#f6b9b9; --na:#eceef1; --link:#0b5cad; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#e3e7ec; --bg:#16191d; --mut:#9aa4b1; --line:#353b43; --head:#20242a;
          --ok:#1f5130; --ovl:#6a5014; --bad:#7a2626; --na:#262a30; --link:#7cb7ff; } }
body { font: 14px/1.45 system-ui, sans-serif; color: var(--fg); background: var(--bg);
       margin: 0; padding: 16px; }
a { color: var(--link); }
h1 { font-size: 1.5em; margin: 0 0 4px; }
h2 { font-size: 1.25em; margin: 32px 0 8px; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
h3 { font-size: 1.05em; margin: 20px 0 6px; }
.mut { color: var(--mut); }
table { border-collapse: collapse; margin: 6px 0 12px; }
th, td { border: 1px solid var(--line); padding: 3px 7px; vertical-align: top; text-align: left; }
th { background: var(--head); }
.wrap { overflow-x: auto; }
.matrix td, .matrix th { text-align: center; min-width: 30px; padding: 2px 4px; font-variant-numeric: tabular-nums; }
.matrix td a { color: inherit; text-decoration: none; display: block; }
.matrix .ttl { text-align: left; max-width: 28em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.matrix .who { text-align: left; white-space: nowrap; }
.ok { background: var(--ok); } .ovl { background: var(--ovl); }
.bad { background: var(--bad); } .na { background: var(--na); }
.legend span { display: inline-block; padding: 1px 8px; margin-right: 6px; border: 1px solid var(--line); }
code { font-size: 0.92em; }
ul { margin: 4px 0; }
EOF

sub write
{
  my ($file, $res, $meta) = @_;
  my $repo = $meta->{repo};
  my $prs  = $res->{prs};
  my $h = '';

  my $prlink = sub
    {
      my $n = shift;
      my $p = $prs->{$n};
      return sprintf ('<a href="%s" title="%s">#%d</a>', _e ($p->{url}), _e ($p->{title}), $n);
    };
  my $filelink = sub
    {
      my ($base, $f) = @_;
      my $url = $repo ? "https://github.com/$repo/blob/$base/$f->{path}" : undef;
      my $name = '<code>' . _e ($f->{path}) . '</code>';
      $name = sprintf ('<a href="%s">%s</a>', _e ($url), $name) if ($url);
      return $name . (defined ($f->{type}) ? ' <span class="mut">(' . _e ($f->{type}) . ')</span>' : '');
    };

  # GitHub pages for a pair: direct diff between the two PR heads, and the
  # changes of each PR to a given file
  my $cmpurl = sub
    {
      my ($p, $path) = @_;
      return GitCross::GitHub::compare_url ($repo, $prs->{$p->{a}}{sha}, $prs->{$p->{b}}{sha}, $path);
    };
  my $pairfile = sub
    {
      my ($p, $path, $html) = @_;
      return $html unless ($repo);
      return sprintf ('%s <span class="mut">[changes in <a href="%s">#%d</a>, <a href="%s">#%d</a>; '
                    . '<a href="%s">diff</a>]</span>', $html,
                      _e (GitCross::GitHub::pr_file_url ($prs->{$p->{a}}{url}, $path)), $p->{a},
                      _e (GitCross::GitHub::pr_file_url ($prs->{$p->{b}}{url}, $path)), $p->{b},
                      _e ($cmpurl->($p, $path)));
    };

  my $nconf = grep { $_->{base_status} ne 'clean' } values %$prs;
  my $npair = 0;
  $npair += grep { $_->{status} eq 'conflict' } values %{ $_->{pairs} } for (@{ $res->{bases} });

  $h .= sprintf ("<h1>Conflict report: %s</h1>\n", _e ($repo));
  $h .= sprintf ("<p class=\"mut\">Generated %s. %d open PRs, %d base branches, "
               . "%d PRs conflicting with their base, %d conflicting PR pairs.</p>\n",
                 _e ($meta->{generated}), scalar (keys %$prs), scalar (@{ $res->{bases} }),
                 $nconf, $npair);
  $h .= <<'EOF';
<p class="legend"><span class="ok">clean</span><span class="ovl">same files, merges cleanly</span><span class="bad">conflict</span><span class="na">no common file</span>
Diagonal: PR against its base branch. Diagonal number: files conflicting with the base. Other cells: number of conflicting files for the pair.</p>
EOF
  $h =~ s{</p>\n\z}{ Rows and columns are sorted from the least to the most problematic PR (see the Problems column).</p>\n}
    unless (($meta->{sort} // q{problem}) eq q{number});

  $h .= "<p>Base branches: " . join (', ', map { sprintf ('<a href="#base-%s">%s</a> (%d)', _e ($_->{name}), _e ($_->{name}), scalar (@{ $_->{prs} })) } @{ $res->{bases} })
      . ". See also <a href=\"#prs\">all PRs</a> and <a href=\"#files\">most conflicting files</a>.</p>\n";

  for my $bb (@{ $res->{bases} })
    {
      my @n = GitCross::Analyze::matrix_order ($bb, $meta->{sort});
      my $pairs = $bb->{pairs};
      $h .= sprintf ("<h2 id=\"base-%s\">Base <code>%s</code></h2>\n", _e ($bb->{name}), _e ($bb->{name}));
      $h .= sprintf ("<p class=\"mut\">At %s. %d PRs.</p>\n", substr ($bb->{sha}, 0, 12), scalar (@n));
      $h .= "<p><b>Can be merged now, in any order</b> (clean against the base and against every other PR): "
          . (@{ $bb->{ready} } ? join (' ', map { $prlink->($_) } @{ $bb->{ready} }) : 'none') . "</p>\n";
      if (@{ $bb->{clusters} })
        {
          $h .= "<p><b>Groups of PRs linked by conflicts</b> (merge one, then the others must be updated):</p><ul>\n";
          $h .= '<li>' . join (' ', map { $prlink->($_) } @$_) . "</li>\n" for (@{ $bb->{clusters} });
          $h .= "</ul>\n";
        }

      # Matrix
      $h .= "<div class=\"wrap\"><table class=\"matrix\"><tr><th>PR</th>"
          . join ('', map { '<th>' . $prlink->($_) . '</th>' } @n)
          . "<th class=\"ttl\">Title</th><th class=\"who\">Contributor</th><th class=\"who\">Problems</th></tr>\n";
      for my $i (@n)
        {
          $h .= '<tr><th>' . $prlink->($i) . '</th>';
          for my $j (@n)
            {
              if ($i == $j)
                {
                  my $p = $prs->{$i};
                  my $bad = $p->{base_status} ne 'clean';
                  $h .= sprintf ('<td class="%s" title="#%d vs %s: %s"><a href="#pr-%d">%s</a></td>',
                                 $bad ? 'bad' : 'ok', $i, _e ($bb->{name}), $p->{base_status}, $i,
                                 $bad ? scalar (@{ $p->{base_conflicts} }) : 'B');
                  next;
                }
              my ($x, $y) = $i < $j ? ($i, $j) : ($j, $i);
              my $p = $pairs->{"$x,$y"};
              if (! $p)
                {
                  $h .= '<td class="na"></td>';
                }
              elsif ($p->{status} eq 'conflict')
                {
                  $h .= sprintf ('<td class="bad" title="%s"><a href="#pair-%d-%d">%d</a></td>',
                                 _e (join ("\n", map { $_->{path} } @{ $p->{files} })), $x, $y, scalar (@{ $p->{files} }));
                }
              else
                {
                  $h .= sprintf ('<td class="ovl" title="%s"><a href="#pair-%d-%d">=</a></td>',
                                 _e (join ("\n", @{ $p->{common} })), $x, $y);
                }
            }
          $h .= sprintf (qq{<td class="ttl" title="%s">%s</td><td class="who">%s</td><td class="who">%s</td></tr>\n},
                         _e ($prs->{$i}{title}), _e ($prs->{$i}{title}), _e ($prs->{$i}{author}),
                         _e (GitCross::Analyze::problems_text ($prs->{$i})));
        }
      $h .= "</table></div>\n";

      # Pairs
      my @pl = sort { ($a->{status} eq 'conflict' ? 0 : 1) <=> ($b->{status} eq 'conflict' ? 0 : 1)
                      || $a->{a} <=> $b->{a} || $a->{b} <=> $b->{b} } values %$pairs;
      if (@pl)
        {
          $h .= "<h3>PR pairs touching common files</h3>\n<div class=\"wrap\"><table>"
              . "<tr><th>Pair</th><th>Status</th><th>On GitHub</th><th>Conflicting files</th><th>Common files</th><th>Note</th></tr>\n";
          for my $p (@pl)
            {
              my $bad = $p->{status} eq 'conflict';
              $h .= sprintf ("<tr id=\"pair-%d-%d\"><td>%s / %s</td><td class=\"%s\">%s</td><td>%s</td><td>%s</td><td>%s</td><td class=\"mut\">%s</td></tr>\n",
                             $p->{a}, $p->{b}, $prlink->($p->{a}), $prlink->($p->{b}),
                             $bad ? 'bad' : 'ovl', $bad ? 'conflict' : 'merges cleanly',
                             $repo ? sprintf ('<a href="%s">diff #%d..#%d</a>', _e ($cmpurl->($p)), $p->{a}, $p->{b}) : '',
                             join ('<br>', map { $pairfile->($p, $_->{path}, $filelink->($bb->{name}, $_)) } @{ $p->{files} }),
                             join ('<br>', map { $pairfile->($p, $_, '<code>' . _e ($_) . '</code>') } @{ $p->{common} }),
                             _e ($p->{note}));
            }
          $h .= "</table></div>\n";
        }
    }

  # All PRs
  $h .= "<h2 id=\"prs\">All PRs</h2>\n<div class=\"wrap\"><table>"
      . "<tr><th>PR</th><th>Title</th><th>Author</th><th>Base</th><th>Draft</th><th>Behind base</th>"
      . "<th>Changed files</th><th>vs base</th><th>Files conflicting with base</th><th>Conflicts with PRs</th></tr>\n";
  my %with;
  for my $bb (@{ $res->{bases} })
    {
      for my $p (grep { $_->{status} eq 'conflict' } values %{ $bb->{pairs} })
        {
          push @{ $with{$p->{a}} }, $p->{b};
          push @{ $with{$p->{b}} }, $p->{a};
        }
    }
  for my $n (sort { $a <=> $b } keys %$prs)
    {
      my $p = $prs->{$n};
      my $bad = $p->{base_status} ne 'clean';
      $h .= sprintf ("<tr id=\"pr-%d\"><td>%s</td><td>%s</td><td>%s</td><td><code>%s</code></td><td>%s</td>"
                   . "<td>%d</td><td>%d</td><td class=\"%s\">%s</td><td>%s</td><td>%s</td></tr>\n",
                     $n, $prlink->($n), _e ($p->{title}), _e ($p->{author}), _e ($p->{base}),
                     $p->{draft} ? 'yes' : '', $p->{behind}, scalar (@{ $p->{changed} }),
                     $bad ? 'bad' : 'ok', $p->{base_status},
                     join ('<br>', map { $filelink->($p->{base}, $_) } @{ $p->{base_conflicts} }),
                     join (' ', map { $prlink->($_) } sort { $a <=> $b } @{ $with{$n} // [] }));
    }
  $h .= "</table></div>\n";

  # Hot files
  $h .= "<h2 id=\"files\">Most conflicting files</h2>\n";
  if (@{ $res->{hot_files} })
    {
      $h .= "<div class=\"wrap\"><table><tr><th>File</th><th>Conflicts</th><th>PRs conflicting with base</th><th>Conflicting pairs</th></tr>\n";
      for my $f (@{ $res->{hot_files} })
        {
          $h .= sprintf ("<tr><td><code>%s</code></td><td>%d</td><td>%s</td><td>%s</td></tr>\n",
                         _e ($f->{path}), $f->{count},
                         join (' ', map { $prlink->($_) } @{ $f->{base} }),
                         join (' ', map { my ($x, $y) = split (m,/,o); sprintf ('<a href="#pair-%d-%d">%d/%d</a>', $x, $y, $x, $y) } @{ $f->{pairs} }));
        }
      $h .= "</table></div>\n";
    }
  else
    {
      $h .= "<p>No conflicts.</p>\n";
    }

  $h .= "<p class=\"mut\">Notes: only textual (git) conflicts are detected; PRs that merge cleanly "
      . "but break the build together are not. Pairs are only tested when both PRs target the same base "
      . "and change at least one common file. A pair is tested by merging the first PR (one that merges "
      . "cleanly into the base) into the base, then merging the other PR on top of it. "
      . "On GitHub, &quot;diff&quot; is the direct difference between the two PR heads: it also contains "
      . "the changes of the base branch when the two PRs are not based on the same commit; "
      . "&quot;changes in #N&quot; shows what PR N does to the file.</p>\n";

  open (my $fh, '>:encoding(UTF-8)', $file) or die "Cannot write $file: $!\n";
  print $fh "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
          . "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
          . "<title>Conflicts " . _e ($repo) . "</title>\n<style>\n$CSS</style></head><body>\n"
          . $h . "</body></html>\n";
  close ($fh);
}

1;
