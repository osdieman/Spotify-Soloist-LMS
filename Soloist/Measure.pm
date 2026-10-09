package Plugins::Soloist::Measure;

# Reads what Bin/soloist-measure.pl found in the captured audio and turns it
# into a verdict for the current Spotify track:
#   '16' / '24'   lossless 16-bit or 24-bit, values untouched
#   '16' / '24'   also when the values sit on a 16/24-bit grid scaled by at
#                 most 0.01% (a decoder dividing by 32767 or 8388607): the
#                 samples are still the original values, one to one
#   'G16<dB>'     a clean 16-bit or 24-bit grid scaled by a gain (e.g.
#   'G24<dB>'     'G16-3.9'): lossless source, but its level was changed,
#                 typically by Spotify's loudness normalisation in Soloist
#   'X'           no integer grid at all: lossy or dithered
#   undef         not enough audio of this track yet, or not clear-cut;
#                 the label then claims nothing
#
# The state file is in /tmp (RAM), one line per 0.5 s block:
# "<epoch> <16|24|X|Z> <gain|-> <fit|-> <levels> <16|24|->".

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

    my (%count, %gains, $noGrid, $blocks);
    if (open my $fh, '<', STATE_FILE) {
        while (my $line = <$fh>) {
            my ($t, $c, $gain, $fit, $grid) =
                $line =~ /\A([\d.]+)\s+(16|24|X|Z)(?:\s+(\S+)\s+(\S+)\s+\d+(?:\s+(16|24|-))?)?/ or next;
            $grid = '16' if defined $fit && !defined $grid && $fit ne '-' && $fit >= FIT_GRID;    # 0.1.32 lines
            next if $t < $since + SETTLE || ($until && $t > $until) || $c eq 'Z';
            $blocks++;
            $count{$c}++;
            next unless $c eq 'X' && defined $fit && $fit ne '-';
            if (defined $grid && $grid ne '-' && $fit >= FIT_GRID && $gain > 0.05) {
                push @{ $gains{$grid} }, $gain;
            }
            elsif ($fit < FIT_NONE || (defined $grid && $grid eq '-')) { $noGrid++ }
        }
        close $fh;
    }
    # The grid most X blocks agree on, and its median gain.
    my ($bits) = sort { @{ $gains{$b} } <=> @{ $gains{$a} } || $a cmp $b } keys %gains;
    my @gridGains = $bits ? sort { $a <=> $b } @{ $gains{$bits} } : ();
    my $gain = @gridGains ? $gridGains[int(@gridGains / 2)] : undef;

    my $verdict;
    my ($best) = sort { ($count{$b} || 0) <=> ($count{$a} || 0) || $a cmp $b } keys %count;
    if ($best && $best ne 'X' && $count{$best} >= MIN_BLOCKS) {
        $verdict = $best;
    }
    elsif ($best && $best eq 'X') {
        my $x = $count{X};
        if (defined $gain && @gridGains >= MIN_BLOCKS && @gridGains >= 0.6 * $x) {
            $verdict = abs($gain - 1) <= SCALE_TOL ? $bits
                     : sprintf('G%d%+.1f', $bits, 20 * log($gain) / log(10));
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
        bits    => $bits,
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
    $text .= sprintf('; %d-bit grid, gain %.5f (%+.2f dB)', $r->{bits}, $r->{gain}, 20 * log($r->{gain}) / log(10))
        if defined $r->{gain};
    $text .= ' = decoder scale, values unchanged'
        if defined $r->{gain} && $r->{gain} != 1 && abs($r->{gain} - 1) <= SCALE_TOL;
    $text .= ' -> ' . (labelPart($r->{verdict}) || 'no verdict');
    return $text;
}

# The part of the LMS label that comes from the measurement.
sub labelPart {
    my ($verdict) = @_;
    return unless defined $verdict;
    return "LOSSLESS $verdict-bit" if $verdict eq '16' || $verdict eq '24';
    return "$1-bit (gain $2 dB)"   if $verdict =~ /\AG(16|24)([-+][\d.]+)\z/;
    return 'NOT BIT-PERFECT'       if $verdict eq 'X';
    return;
}

1;
