#!/usr/bin/perl
# Soloist Connect: measure what Spotify actually delivers.
#
# Sits in the capture pipeline:  arecord -f S32_LE ... | soloist-measure.pl STATEFILE | flac --bps=24 ...
# Input:  raw S32_LE stereo (ALSA converts Soloist's float exactly: x * 2^31).
# Output: raw S24_3LE (the low byte of every sample dropped), passed on at once.
#
# Every 0.5 s of audio it classifies the block by which bits are in use:
#   16  only the top 16 bits used      -> lossless 16-bit source
#   24  bits below 16 used, not the low byte -> lossless 24-bit source
#   X   the low byte is used too       -> not on any integer grid: lossy
#                                         stream, or volume/normalisation
#   Z   digital silence
# and keeps the last 120 blocks with their time in STATEFILE (in /tmp, RAM),
# which the plugin reads to label the current track.

use strict;
use warnings;
use Time::HiRes ();

my $state = shift @ARGV;
binmode STDIN;
binmode STDOUT;
$| = 1;

use constant BLOCK_BYTES => 44100 * 2 * 4 / 2;   # 0.5 s of stereo S32
use constant KEEP        => 120;                   # blocks in the state file

my ($nonzero, $low, $mid, $seen) = (0, 0, 0, 0);
my @blocks;
my $rest = '';
my %mask;

sub masks {
    my ($len) = @_;
    my $n = $len / 4;
    $mask{$len} ||= [ ("\xff\0\0\0" x $n), ("\0\xff\0\0" x $n) ];
    return @{ $mask{$len} };
}

sub flush_block {
    my $class = !$nonzero ? 'Z' : $low ? 'X' : $mid ? '24' : '16';
    push @blocks, sprintf('%.3f %s', Time::HiRes::time(), $class);
    shift @blocks while @blocks > KEEP;
    ($nonzero, $low, $mid, $seen) = (0, 0, 0, 0);
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
