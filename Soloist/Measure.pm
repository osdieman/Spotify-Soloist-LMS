package Plugins::Soloist::Measure;

# Reads what Bin/soloist-measure.pl found in the captured audio and turns it
# into a verdict for the current Spotify track:
#   '16' / '24'   lossless 16-bit or 24-bit, values untouched
#   '16'          also when the values sit on a 16-bit grid that is scaled by
#                 at most 0.01% (e.g. a decoder that divides by 32767): the
#                 samples are still the original 16-bit values, one to one
#   'G<dB>'       a clean 16-bit grid scaled by a gain (e.g. 'G-2.0'):
#                 lossless source, but something changed the level
#   'X'           no integer grid at all: lossy or dithered
#   undef         not enough audio of this track yet, or not clear-cut;
#                 the label then claims nothing
#
# The state file is in /tmp (RAM), one line per 0.5 s block:
# "<epoch> <16|24|X|Z> <gain|-> <fit|-> <levels>".

use strict;
use warnings;
use Time::HiRes ();

use constant STATE_FILE => '/tmp/soloist-measure';
use constant SETTLE     => 1.5;    # s after a track change before blocks count
use constant MIN_BLOCKS => 4;      # 2 s of agreeing blocks before any verdict
use constant FIT_GRID   => 0.90;   # block "on a grid" at this fit or better
use constant FIT_NONE   => 0.50;   # block "on no grid" below this fit
use constant SCALE_TOL  => 0.0001; # |gain - 1| up to this = original values

my $cache;    # [time, since, until, result]

sub stateFile { return STATE_FILE; }

sub verdict {
    my ($class, $since, $until) = @_;
    return $class->analyse($since, $until)->{verdict};
}

# Everything the log line needs: counts, median gain, verdict.
sub analyse {
    my ($class, $since, $until) = @_;
    $since ||= 0;
    $until ||= 0;
    my $now = Time::HiRes::time();
    return $cache->[3]
        if $cache && $now - $cache->[0] < 1 && $cache->[1] == $since && $cache->[2] == $until;

    my (%count, @gridGains, $noGrid, $blocks);
    if (open my $fh, '<', STATE_FILE) {
        while (my $line = <$fh>) {
            my ($t, $c, $gain, $fit) = $line =~ /\A([\d.]+)\s+(16|24|X|Z)(?:\s+(\S+)\s+(\S+))?/ or next;
            next if $t < $since + SETTLE || ($until && $t > $until) || $c eq 'Z';
            $blocks++;
            $count{$c}++;
            next unless $c eq 'X' && defined $fit && $fit ne '-';
            if ($fit >= FIT_GRID && $gain > 0.05) { push @gridGains, $gain }
            elsif ($fit < FIT_NONE)              { $noGrid++ }
        }
        close $fh;
    }
    @gridGains = sort { $a <=> $b } @gridGains;
    my $gain = @gridGains ? $gridGains[int(@gridGains / 2)] : undef;

    my $verdict;
    my ($best) = sort { ($count{$b} || 0) <=> ($count{$a} || 0) || $a cmp $b } keys %count;
    if ($best && $best ne 'X' && $count{$best} >= MIN_BLOCKS) {
        $verdict = $best;
    }
    elsif ($best && $best eq 'X') {
        my $x = $count{X};
        if (defined $gain && @gridGains >= MIN_BLOCKS && @gridGains >= 0.6 * $x) {
            $verdict = abs($gain - 1) <= SCALE_TOL ? '16'
                     : sprintf('G%+.1f', 20 * log($gain) / log(10));
        }
        elsif (($noGrid || 0) >= MIN_BLOCKS && $noGrid >= 0.6 * $x) {
            $verdict = 'X';
        }
    }

    my $result = {
        verdict => $verdict,
        blocks  => $blocks || 0,
        count   => \%count,
        gain    => $gain,
        onGrid  => scalar @gridGains,
        noGrid  => $noGrid || 0,
    };
    $cache = [$now, $since, $until, $result];
    return $result;
}

# One line for soloist.log about a finished (or current) track.
sub summary {
    my ($class, $since, $until) = @_;
    my $r = $class->analyse($since, $until);
    return unless $r->{blocks};
    my $c = $r->{count};
    my $text = sprintf('blocks 16:%d 24:%d X:%d', $c->{16} || 0, $c->{24} || 0, $c->{X} || 0);
    $text .= sprintf('; X blocks on a grid %d, on no grid %d', $r->{onGrid}, $r->{noGrid}) if $c->{X};
    $text .= sprintf('; grid gain %.5f (%+.2f dB)', $r->{gain}, 20 * log($r->{gain}) / log(10))
        if defined $r->{gain};
    $text .= ' = decoder scale 1/32767, values unchanged'
        if defined $r->{gain} && abs($r->{gain} - 32768 / 32767) < 0.00001;
    $text .= ' -> ' . (labelPart($r->{verdict}) || 'no verdict');
    return $text;
}

# The part of the LMS label that comes from the measurement.
sub labelPart {
    my ($verdict) = @_;
    return unless defined $verdict;
    return "LOSSLESS $verdict-bit" if $verdict eq '16' || $verdict eq '24';
    return "16-bit (gain $1 dB)"   if $verdict =~ /\AG([-+][\d.]+)\z/;
    return 'NOT BIT-PERFECT'       if $verdict eq 'X';
    return;
}

1;
