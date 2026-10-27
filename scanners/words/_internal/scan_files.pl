#!/usr/bin/env perl
# The word-list scan of one file, run by anon-scan.sh for each file it scans: a text file line by
# line, a binary file by the runs of text inside it, a zip archive (an .aar, a .jar) member by member.
#
#   ANON_PATTERN=<alternation> [ANON_LABEL=<name to report>] perl scan_file.pl <file>
#
# Prints `<label>:<line>:<text>` for each hit (`<label>!<member>` inside an archive, `text <n>` for
# the n-th run of a binary), and exits 1 when anything was found or could not be read, else 0.
# Compressed bytes are never read as text: three letters of a word list fall in them by chance.
use strict;
use warnings;
use Encode qw(decode);
use IO::Uncompress::Unzip qw($UnzipError);
use Unicode::Normalize qw(NFKC);

# git's own test: a NUL in the first 8000 bytes makes a file binary.
my $PROBE = 8000;
# A run of text inside a binary: twelve or more printable ASCII characters, or three or more
# Japanese ones (UTF-8 of three bytes, with short ASCII between them). A path or a name a build
# wrote into it is one. In 100 MB of random bytes runs of eight held three-letter words by chance;
# runs of twelve held none, and three Japanese characters none.
my $ASCII_RUN = qr/[\x09\x20-\x7e]{12,}/;
my $WIDE_RUN = qr/(?:[\xe3-\xe9][\x80-\xbf]{2})+(?:[\x20-\x7e]{0,8}(?:[\xe3-\xe9][\x80-\xbf]{2})+)*/;
my $WIDE_LENGTH = 3;
my $CHUNK = 1 << 20;
# How much of a run reaching the end of a chunk is carried into the next one.
my $CARRY_MAX = 1 << 16;
# How many archives deep a member is opened (an .aar holds a classes.jar).
my $NESTED = 3;
# What a hit in a binary shows: this many characters, starting a little before the match.
my $SHOWN = 200;
my $LEAD = 60;
my $ZIP = "PK\x03\x04";

my $pattern = NFKC(decode("UTF-8", $ENV{ANON_PATTERN} // ""));
my $re = qr/(?i)$pattern/;
binmode STDOUT, ":encoding(UTF-8)";
binmode STDERR, ":encoding(UTF-8)";
my $found = 0;

sub report {
    my ($label, $where, $text) = @_;
    $text =~ s/\R\z//;
    print "$label:$where:$text\n";
    $found = 1;
}

sub unreadable {
    my ($label, $why) = @_;
    print STDERR "$label: $why; NOT scanned\n";
    $found = 1;
}

sub scan_lines {
    my ($label, $next_line) = @_;
    my $n = 0;
    while (defined(my $line = $next_line->())) {
        $n++;
        my $text = decode("UTF-8", $line);
        report($label, $n, $text) if NFKC($text) =~ $re;
    }
}

sub scan_runs {
    my ($label, $next_chunk) = @_;
    my ($carry, $count) = ("", 0);
    my $flush = sub {
        my ($bytes) = @_;
        my @runs;
        while ($bytes =~ /($ASCII_RUN)/g) {
            push @runs, [$-[0], decode("UTF-8", $1)];
        }
        while ($bytes =~ /($WIDE_RUN)/g) {
            my $text = decode("UTF-8", $1);
            push @runs, [$-[0], $text] if length($text) >= $WIDE_LENGTH;
        }
        for my $run (sort { $a->[0] <=> $b->[0] } @runs) {
            $count++;
            my $folded = NFKC($run->[1]);
            next unless $folded =~ $re;
            my $from = $-[0] > $LEAD ? $-[0] - $LEAD : 0;
            report($label, "text $count", substr($folded, $from, $SHOWN));
        }
    };
    while (defined(my $chunk = $next_chunk->())) {
        my $buffer = $carry . $chunk;
        # Keep what follows the last byte that cannot be in a run: it may go on in the next chunk.
        my $cut = $buffer =~ /.*[^\x09\x20-\x7e\x80-\xff]/s ? $+[0] : 0;
        $cut = length($buffer) - $CARRY_MAX if length($buffer) - $cut > $CARRY_MAX;
        $flush->(substr($buffer, 0, $cut));
        $carry = substr($buffer, $cut);
    }
    $flush->($carry);
}

sub scan_zip {
    my ($label, $source, $depth) = @_;
    my $zip = IO::Uncompress::Unzip->new($source)
        or return unreadable($label, "could not be opened as a zip archive ($UnzipError)");
    my $status = 1;
    while ($status > 0) {
        my $name = $zip->getHeaderInfo()->{Name} // "";
        my ($data, $buffer) = ("", "");
        while (($status = $zip->read($buffer, $CHUNK)) > 0) {
            $data .= $buffer;
        }
        last if $status < 0;
        scan_bytes("$label!$name", \$data, $depth + 1) unless $name =~ m{/\z};
        $status = $zip->nextStream();
    }
    unreadable($label, "a member could not be read ($UnzipError)") if $status < 0;
}

sub scan_bytes {
    my ($label, $data, $depth) = @_;
    if (substr($$data, 0, 4) eq $ZIP && $depth < $NESTED) {
        return scan_zip($label, $data, $depth);
    }
    if (index(substr($$data, 0, $PROBE), "\0") >= 0) {
        my $given = 0;
        return scan_runs($label, sub { $given++ ? undef : $$data });
    }
    open(my $handle, "<:raw", $data) or return unreadable($label, "could not be read");
    scan_lines($label, sub { scalar <$handle> });
}

sub scan_path {
    my ($path, $label) = @_;
    open(my $handle, "<:raw", $path) or return unreadable($label, "could not be opened ($!)");
    read($handle, my $head, $PROBE);
    $head //= "";
    if (substr($head, 0, 4) eq $ZIP) {
        close($handle);
        return scan_zip($label, $path, 0);
    }
    seek($handle, 0, 0);
    if (index($head, "\0") >= 0) {
        return scan_runs($label, sub { local $/ = \$CHUNK; scalar <$handle> });
    }
    scan_lines($label, sub { scalar <$handle> });
}

my $path = shift @ARGV // die "usage: scan_file.pl <file>\n";
scan_path($path, decode("UTF-8", $ENV{ANON_LABEL} // $path));
exit($found ? 1 : 0);
