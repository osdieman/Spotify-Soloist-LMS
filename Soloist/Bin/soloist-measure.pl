#!/usr/bin/perl
# Soloist Connect: measure what Spotify actually delivers.
#
# Sits in the capture pipeline:  arecord -f S32_LE ... | soloist-measure.pl STATEFILE | flac --bps=24 ...
# Input:  raw S32_LE stereo. Soloist plays FLOAT_LE into the Loopback and
#         ALSA converts it exactly (x * 2^31).
# Output: raw S24_3LE (the low byte of every sample dropped), passed on at once.
#
# Every 0.5 s of audio it writes one line to STATEFILE (in /tmp, RAM):
#   <epoch> <class> <gain> <fit> <levels> <grid>
# class, from which bits are in use:
#   16  only the top 16 bits used            -> lossless 16-bit on the standard grid
#   24  bits below 16 used, not the low byte -> lossless 24-bit
#   X   the low byte is used too             -> not on the standard grid
#   Z   digital silence
# gain/fit/levels/grid, from the quiet samples (16-bit level < 256), where
# a source shows its integer steps even when something scaled it:
#   grid    16  the samples sit on a (scaled) 16-bit grid
#           24  they sit on a (scaled) 24-bit grid
#           -   no grid found (lossy, dithered), or too few quiet samples
#   gain    step between neighbouring levels / one step of that grid
#           (1.00000 standard, 1.00003 = scaled by 32767 / 8388607,
#           0.794 = -2 dB, e.g. Spotify's loudness normalisation)
#   fit     share of the quiet samples on that grid
#   levels  distinct quiet values seen (capped at LEVEL_CAP)
# Keeps the last KEEP lines; Plugins::Soloist::Measure reads them.

use strict;
use warnings;
use Time::HiRes ();

my $state = shift @ARGV;
binmode STDIN;
binmode STDOUT;
$| = 1;

use constant BLOCK_BYTES => 44100 * 2 * 4 / 2;   # 0.5 s of stereo S32
use constant KEEP        => 480;                   # 4 minutes of blocks
use constant QUIET       => 256 * 65536;           # 16-bit level 256 in S32
use constant LEVEL_CAP   => 6000;                  # more distinct values = no grid
use constant TOL         => 4;                     # S32 units of float/rounding slack
use constant MIN_LEVELS  => 24;

my ($nonzero, $low, $mid, $seen) = (0, 0, 0, 0);
my %quiet;
my $quietFull = 0;
my @blocks;
my $rest = '';
my %mask;

sub masks {
    my ($len) = @_;
    my $n = $len / 4;
    $mask{$len} ||= [ ("\xff\0\0\0" x $n), ("\0\xff\0\0" x $n) ];
    return @{ $mask{$len} };
}

# Grid tests work on the gaps between neighbouring quiet values: on a grid,
# every gap is a whole number of steps. Gaps span only a few steps, so a
# tiny error in the step can't add up the way it would over absolute values.
use constant MAX_K => 50;    # ignore gaps longer than this many steps

# Sharpen a rough step: average the gaps that are close to whole multiples.
sub refine {
    my ($step, $gaps) = @_;
    for (1 .. 3) {
        my ($sum, $ks) = (0, 0);
        for my $g (@$gaps) {
            my $k = int($g / $step + 0.5);
            next if $k < 1 || $k > MAX_K || abs($g - $k * $step) > 0.25 * $step;
            $sum += $g;
            $ks  += $k;
        }
        $step = $sum / $ks if $ks;
    }
    return $step;
}

# Share of the (short) gaps that are whole multiples of $step within TOL.
sub fit {
    my ($step, $gaps) = @_;
    my ($n, $on) = (0, 0);
    for my $g (@$gaps) {
        my $k = int($g / $step + 0.5);
        next if $k > MAX_K;
        $n++;
        $on++ if $k >= 1 && abs($g - $k * $step) <= TOL;
    }
    return $n >= MIN_LEVELS ? $on / $n : 0;
}

# Which grid the quiet samples sit on, and at what gain.
# 16-bit: neighbouring levels are dense, so the median gap is one step.
# 24-bit: levels are sparse, so the smallest gap is one or a few steps;
#         try it divided by 1..4 and take the coarsest step that fits.
sub grid {
    my @v = sort { $a <=> $b } keys %quiet;
    return ('0.00000', '0.00', LEVEL_CAP, '-') if $quietFull;
    return ('-', '-', scalar @v, '-') if @v < MIN_LEVELS;
    my @gap = sort { $a <=> $b } grep { $_ > 0 } map { $v[$_] - $v[$_ - 1] } 1 .. $#v;
    return ('0.00000', '0.00', scalar @v, '-') unless @gap >= MIN_LEVELS;
    my $step = $gap[int(@gap / 2)];
    my $fit16 = 0;
    if ($step >= 16) {
        $step = refine($step, \@gap);
        $fit16 = fit($step, \@gap);
        return (sprintf('%.5f', $step / 65536), sprintf('%.2f', $fit16), scalar @v, '16')
            if $fit16 >= 0.9;
    }
    if (@v >= 50) {
        for my $m (1 .. 4) {
            my $s = $gap[0] / $m;
            last if $s < 32;    # finer steps than this fit anything within TOL
            $s = refine($s, \@gap);
            my $f = fit($s, \@gap);
            return (sprintf('%.5f', $s / 256), sprintf('%.2f', $f), scalar @v, '24') if $f >= 0.9;
        }
    }
    return (sprintf('%.5f', $step / 65536), sprintf('%.2f', $fit16), scalar @v, '-');
}

sub flush_block {
    my $class = !$nonzero ? 'Z' : $low ? 'X' : $mid ? '24' : '16';
    my ($gain, $fit, $levels, $grid) = $class eq 'Z' ? ('-', '-', 0, '-') : grid();
    push @blocks, sprintf('%.3f %s %s %s %d %s', Time::HiRes::time(), $class, $gain, $fit, $levels, $grid);
    shift @blocks while @blocks > KEEP;
    ($nonzero, $low, $mid, $seen) = (0, 0, 0, 0);
    %quiet = ();
    $quietFull = 0;
    return unless $state;
    my $tmp = "$state.tmp";
    if (open my $fh, '>', $tmp) {
        print {$fh} join("\n", @blocks), "\n";
        close $fh;
        rename $tmp, $state;
    }
}

while (1) {
    my $buf = '';
    my $n = sysread(STDIN, $buf, 65536);
    last unless $n;
    $buf = $rest . $buf;
    my $usable = length($buf) - length($buf) % 4;
    $rest = substr($buf, $usable);
    next unless $usable;
    my $chunk = substr($buf, 0, $usable);

    my ($m0, $m1) = masks($usable);
    $low += (($chunk & $m0) =~ tr/\0//c);
    $mid += (($chunk & $m1) =~ tr/\0//c);
    $nonzero ||= ($chunk =~ tr/\0//c) ? 1 : 0;

    unless ($quietFull) {
        for my $s (unpack('l<*', $chunk)) {
            next unless $s && $s < QUIET && $s > -QUIET;
            $quiet{abs $s} = 1;
        }
        $quietFull = 1 if keys %quiet > LEVEL_CAP;
    }

    my $out = join '', unpack('(x a3)*', $chunk);
    my $off = 0;
    while ($off < length $out) {
        my $w = syswrite(STDOUT, $out, length($out) - $off, $off);
        exit 0 unless defined $w && $w > 0;
        $off += $w;
    }

    $seen += $usable;
    flush_block() if $seen >= BLOCK_BYTES;
}
exit 0;
