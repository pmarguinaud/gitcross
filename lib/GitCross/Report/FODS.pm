package GitCross::Report::FODS;

# LibreOffice spreadsheet report, as flat OpenDocument XML (.fods):
# one sheet per base branch with the PR x PR matrix, plus PRs, Pairs and Files

use strict;
use warnings;

sub _e
{
  my $s = shift // '';
  $s =~ s/&/&amp;/go;
  $s =~ s/</&lt;/go;
  $s =~ s/>/&gt;/go;
  $s =~ s/"/&quot;/go;
  return $s;
}

my %COLOR = (ok => '#c9ebcf', ovl => '#ffe2a8', bad => '#f6b9b9', na => '#eceef1', hdr => '#dde3ea');

# Cell: string, number, or { v => value, s => style, href => url }
sub _cell
{
  my $c = shift;
  $c = { v => $c } unless (ref ($c));
  my $v = $c->{v} // '';
  my $style = $c->{s} ? " table:style-name=\"$c->{s}\"" : '';
  if ($v =~ m/^-?\d+$/o && ! $c->{href})
    {
      return "<table:table-cell$style office:value-type=\"float\" office:value=\"$v\"><text:p>$v</text:p></table:table-cell>";
    }
  my $paras = join ('', map
    {
      $c->{href}
        ? sprintf ('<text:p><text:a xlink:type="simple" xlink:href="%s">%s</text:a></text:p>', _e ($c->{href}), _e ($_))
        : '<text:p>' . _e ($_) . '</text:p>'
    } split (m/\n/o, $v, -1));
  $paras ||= '<text:p/>';
  return "<table:table-cell$style office:value-type=\"string\">$paras</table:table-cell>";
}

sub _sheet
{
  my ($name, $widths, @rows) = @_;
  $name =~ s/[\[\]*?:\/\\']/_/go;
  my $x = sprintf ("<table:table table:name=\"%s\">\n", _e ($name));
  $x .= "<table:table-column table:style-name=\"co$_\"/>" for (@$widths);
  $x .= "\n";
  for my $r (@rows)
    {
      $x .= '<table:table-row>' . join ('', map { _cell ($_) } @$r) . "</table:table-row>\n";
    }
  return $x . "</table:table>\n";
}

sub write
{
  my ($file, $res, $meta) = @_;
  my $prs  = $res->{prs};
  my $repo = $meta->{repo};
  my @sheets;
  my $H = sub { map { +{ v => $_, s => 'hdr' } } @_ };
  my $pr = sub { my $n = shift; return +{ v => "#$n", href => $prs->{$n}{url} } };

  # Summary
  my @sum = ([$H->('Repository'), $repo], [$H->('Generated'), $meta->{generated}], [],
             [$H->('Base', 'PRs', 'Conflicting with base', 'Conflicting pairs', 'Can be merged now', 'Conflict groups')]);
  for my $bb (@{ $res->{bases} })
    {
      push @sum, [ $bb->{name}, scalar (@{ $bb->{prs} }),
                   scalar (grep { $prs->{$_}{base_status} ne 'clean' } @{ $bb->{prs} }),
                   scalar (grep { $_->{status} eq 'conflict' } values %{ $bb->{pairs} }),
                   join (' ', map { "#$_" } @{ $bb->{ready} }),
                   join ("\n", map { join (' ', map { "#$_" } @$_) } @{ $bb->{clusters} }) ];
    }
  push @sum, [], [{ v => 'Legend', s => 'hdr' }],
             [{ v => 'clean', s => 'ok' }], [{ v => 'same files, merges cleanly', s => 'ovl' }],
             [{ v => 'conflict', s => 'bad' }], [{ v => 'no common file', s => 'na' }],
             ['Matrix diagonal: PR against its base (B = clean, number = conflicting files).'],
             ['Other matrix cells: number of conflicting files for the pair, "=" if same files but no conflict.'];
  push @sheets, _sheet ('Summary', [qw (w m m m w w)], @sum);

  # One matrix per base
  for my $bb (@{ $res->{bases} })
    {
      my @n = @{ $bb->{prs} };
      my @rows = ([ $H->(q{PR}), (map { +{ %{ $pr->($_) }, s => 'hdr' } } @n), $H->(q{Title}, q{Contributor}) ]);
      for my $i (@n)
        {
          my @r = ({ %{ $pr->($i) }, s => 'hdr' });
          for my $j (@n)
            {
              if ($i == $j)
                {
                  my $p = $prs->{$i};
                  push @r, $p->{base_status} eq 'clean' ? { v => 'B', s => 'ok' }
                                                        : { v => scalar (@{ $p->{base_conflicts} }), s => 'bad' };
                  next;
                }
              my ($x, $y) = $i < $j ? ($i, $j) : ($j, $i);
              my $p = $bb->{pairs}{"$x,$y"};
              push @r, ! $p ? { v => '', s => 'na' }
                     : $p->{status} eq 'conflict' ? { v => scalar (@{ $p->{files} }), s => 'bad' }
                     : { v => '=', s => 'ovl' };
            }
          push @rows, [@r, $prs->{$i}{title}, $prs->{$i}{author}];
        }
      push @sheets, _sheet ("Matrix $bb->{name}", [q{s}, (map { q{n} } @n), qw (w m)], @rows);
    }

  # PRs
  my %with;
  for my $bb (@{ $res->{bases} })
    {
      for my $p (grep { $_->{status} eq 'conflict' } values %{ $bb->{pairs} })
        {
          push @{ $with{$p->{a}} }, $p->{b};
          push @{ $with{$p->{b}} }, $p->{a};
        }
    }
  my @prows = ([$H->('PR', 'Title', 'Author', 'Base', 'Draft', 'Behind base', 'Changed files',
                     'vs base', 'Files conflicting with base', 'Conflicts with PRs')]);
  for my $n (sort { $a <=> $b } keys %$prs)
    {
      my $p = $prs->{$n};
      my $bad = $p->{base_status} ne 'clean';
      push @prows, [ $pr->($n), $p->{title}, $p->{author}, $p->{base}, $p->{draft} ? 'yes' : '',
                     $p->{behind}, scalar (@{ $p->{changed} }),
                     { v => $p->{base_status}, s => $bad ? 'bad' : 'ok' },
                     join ("\n", map { "$_->{path} ($_->{type})" } @{ $p->{base_conflicts} }),
                     join (' ', map { "#$_" } sort { $a <=> $b } @{ $with{$n} // [] }) ];
    }
  push @sheets, _sheet ('PRs', [qw (s w m m s s s s w m)], @prows);

  # Pairs
  my @rows = ([$H->('Base', 'PR A', 'PR B', 'Status', 'Conflicting files', 'Common files', 'Note')]);
  for my $bb (@{ $res->{bases} })
    {
      for my $p (sort { ($a->{status} eq 'conflict' ? 0 : 1) <=> ($b->{status} eq 'conflict' ? 0 : 1)
                        || $a->{a} <=> $b->{a} || $a->{b} <=> $b->{b} } values %{ $bb->{pairs} })
        {
          my $bad = $p->{status} eq 'conflict';
          push @rows, [ $bb->{name}, $pr->($p->{a}), $pr->($p->{b}),
                        { v => $bad ? 'conflict' : 'merges cleanly', s => $bad ? 'bad' : 'ovl' },
                        join ("\n", map { "$_->{path} ($_->{type})" } @{ $p->{files} }),
                        join ("\n", @{ $p->{common} }), $p->{note} // '' ];
        }
    }
  push @sheets, _sheet ('Pairs', [qw (m s s m w w w)], @rows);

  # Files
  @rows = ([$H->('File', 'Conflicts', 'PRs conflicting with base', 'Conflicting pairs')]);
  push @rows, [ $_->{path}, $_->{count}, join (' ', map { "#$_" } @{ $_->{base} }),
                join (' ', @{ $_->{pairs} }) ] for (@{ $res->{hot_files} });
  push @sheets, _sheet ('Files', [qw (w s m w)], @rows);

  my $styles = join ("\n", map
    {
      sprintf ('<style:style style:name="%s" style:family="table-cell"><style:table-cell-properties fo:background-color="%s" fo:border="0.5pt solid #b0b8c2"/>%s</style:style>',
               $_, $COLOR{$_}, $_ eq 'hdr' ? '<style:text-properties fo:font-weight="bold"/>' : '')
    } sort keys %COLOR);
  my %W = (n => '0.45in', s => '0.7in', m => '1.4in', w => '4in');
  $styles .= "\n" . join ("\n", map
    {
      sprintf ('<style:style style:name="co%s" style:family="table-column"><style:table-column-properties style:column-width="%s"/></style:style>', $_, $W{$_})
    } sort keys %W);

  open (my $fh, '>:encoding(UTF-8)', $file) or die "Cannot write $file: $!\n";
  print $fh <<"EOF";
<?xml version="1.0" encoding="UTF-8"?>
<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
 xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
 xmlns:xlink="http://www.w3.org/1999/xlink"
 office:version="1.2" office:mimetype="application/vnd.oasis.opendocument.spreadsheet">
<office:automatic-styles>
$styles
</office:automatic-styles>
<office:body><office:spreadsheet>
@{[ join ('', @sheets) ]}</office:spreadsheet></office:body></office:document>
EOF
  close ($fh);
}

1;
