package Plugins::Soloist::Measure;

# Reads what Bin/soloist-measure.pl found in the captured audio and turns it
# into a verdict for the current Spotify track:
#   16 / 24  lossless 16-bit or 24-bit source (samples on that integer grid)
#   X        not on any grid: lossy stream, or volume/normalisation changed it
#   undef    not enough audio of this track yet
#
# The state file is in /tmp (RAM) and holds one line per 0.5 s block:
# "<epoch seconds> <16|24|X|Z>".

use strict;
use warnings;
use Time::HiRes ();

use constant STATE_FILE => '/tmp/soloist-measure';
use constant SETTLE     => 1.5;    # s after a track change before blocks count
use constant MIN_BLOCKS => 2;

my $cache;    # [time, since, verdict]

sub stateFile { return STATE_FILE; }

sub verdict {
    my ($class, $since) = @_;
    $since ||= 0;
    my $now = Time::HiRes::time();
    return $cache->[2] if $cache && $now - $cache->[0] < 1 && $cache->[1] == $since;
    my %count;
    if (open my $fh, '<', STATE_FILE) {
        while (my $line = <$fh>) {
            my ($t, $c) = $line =~ /\A([\d.]+)\s+(16|24|X|Z)\b/ or next;
            next if $t < $since + SETTLE || $c eq 'Z';
            $count{$c}++;
        }
        close $fh;
    }
    my ($best) = sort { $count{$b} <=> $count{$a} || $a cmp $b } keys %count;
    my $verdict = $best && $count{$best} >= MIN_BLOCKS ? $best : undef;
    $cache = [$now, $since, $verdict];
    return $verdict;
}

1;
