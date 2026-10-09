#!/usr/bin/perl
# Soloist Connect: measure what Spotify actually delivers.
#
# Sits in the capture pipeline:  arecord -f S32_LE ... | soloist-measure.pl STATEFILE | flac --bps=24 ...
# Input:  raw S32_LE stereo. Soloist plays FLOAT_LE into the Loopback and
#         ALSA converts it exactly (x * 2^31).
# Output: raw S24_3LE (the low byte of every sample dropped), passed on at once.
#
# Every 0.5 s of audio it writes one line to STATEFILE (in /tmp, RAM):
#   <epoch> <class> <gain> <fit> <levels>
# class, from which bits are in use:
#   16  only the top 16 bits used            -> lossless 16-bit on the standard grid
#   24  bits below 16 used, not the low byte -> lossless 24-bit
#   X   the low byte is used too             -> not on the standard grid
#   Z   digital silence
# gain/fit/levels, from the quiet samples (16-bit level < 256), where a
# 16-bit source shows clear steps even when something scaled it:
#   gain    step between neighbouring levels / one 16-bit step
#           (1.00000 standard, 1.00003 = scaled by 32767, 0.794 = -2 dB,
#           ~0 = no steps: lossy or dithered)
#   fit     share of the quiet samples that lie on that step grid
#   levels  distinct quiet values seen (capped at LEVEL_CAP)
#   "-" when the block had too few quiet samples to tell.
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
use constant LEVEL_CAP   => 3000;                  # more distinct values = no grid
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

# Step between neighbouring quiet levels (median of the gaps), relative to
# one 16-bit step, and how many quiet values lie on that grid.
sub grid {
    my @v = sort { $a <=> $b } keys %quiet;
    return ('-', '-', scalar @v) if @v < MIN_LEVELS && !$quietFull;
    return ('0.00000', '0.00', LEVEL_CAP) if $quietFull;
    my @gap = sort { $a <=> $b } map { $v[$_] - $v[$_ - 1] } 1 .. $#v;
    my $step = $gap[int(@gap / 2)];
    return ('0.00000', '0.00', scalar @v) if $step < 16;    # no usable steps
    my $on = 0;
    for my $x (@v) {
        my $q = $x / $step;
        $on++ if abs($q - int($q + 0.5)) < 0.02;
    }
    return (sprintf('%.5f', $step / 65536), sprintf('%.2f', $on / @v), scalar @v);
}

sub flush_block {
    my $class = !$nonzero ? 'Z' : $low ? 'X' : $mid ? '24' : '16';
    my ($gain, $fit, $levels) = $class eq 'Z' ? ('-', '-', 0) : grid();
    push @blocks, sprintf('%.3f %s %s %s %d', Time::HiRes::time(), $class, $gain, $fit, $levels);
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
