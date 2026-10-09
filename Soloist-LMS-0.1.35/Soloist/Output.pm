package Plugins::Soloist::Output;

# What actually reaches the DAC. For a squeezelite running on this same
# machine, find the ALSA card it plays to and read the live format from
# /proc/asound/<card>/pcm*p/sub*/hw_params. Players elsewhere on the
# network can't be inspected; for them nothing is returned.
#
# Everything here reads small files in /proc (RAM), and results are cached
# for a few seconds because LMS asks for metadata on every status poll.

use strict;
use warnings;
use Time::HiRes ();

my %cache;          # player id => [time, text]
my $procCache;      # [time, [ { pid, mac, name, device } ... ]]

use constant CACHE_SECONDS => 5;
use constant PROC_SECONDS  => 60;

# "R2R 32-bit/44.1 kHz", or undef when unknown.
sub describe {
    my ($class, $client) = @_;
    return unless $client;
    my $id = eval { $client->id } || return;
    my $now = Time::HiRes::time();
    my $hit = $cache{$id};
    return $hit->[1] if $hit && $now - $hit->[0] < CACHE_SECONDS;
    my $text = eval { _describe($client) };
    $cache{$id} = [$now, $text];
    return $text;
}

sub _describe {
    my ($client) = @_;
    my $squeezelite = _findSqueezelite($client) or return;
    my $card = _cardFor($squeezelite->{device}) or return;
    my ($format, $rate) = _hwParams($card) or return;
    my $name = _longName($card) || _readLine("/proc/asound/$card/id") || $card;
    return "$name " . _depth($format) . '/' . _khz($rate);
}

# The local squeezelite process that belongs to this LMS player: matched by
# MAC (-m), else by name (-n), else the only one running if the player
# connects from this machine.
sub _findSqueezelite {
    my ($client) = @_;
    my $now = Time::HiRes::time();
    if (!$procCache || $now - $procCache->[0] > PROC_SECONDS) {
        $procCache = [$now, [_scanSqueezelite()]];
    }
    my @all = @{ $procCache->[1] };
    return unless @all;
    my $mac = lc(eval { $client->id } || '');
    my ($byMac) = grep { $_->{mac} && lc($_->{mac}) eq $mac } @all;
    return $byMac if $byMac;
    my $name = eval { $client->name } || '';
    my ($byName) = grep { defined $_->{name} && $_->{name} eq $name } @all;
    return $byName if $byName;
    my $ip = eval { $client->ip } || '';
    return $all[0] if @all == 1 && ($ip eq '127.0.0.1' || _isLocalIp($ip));
    return;
}

sub _scanSqueezelite {
    my @found;
    opendir my $dh, '/proc' or return;
    for my $pid (grep { /\A\d+\z/ } readdir $dh) {
        my $comm = _readLine("/proc/$pid/comm") or next;
        next unless $comm =~ /\Asqueezelite/;
        my $raw = _slurp("/proc/$pid/cmdline");
        my @args = split /\0/, $raw;
        my %opt;
        for (my $i = 1; $i < @args; $i++) {
            my $a = $args[$i];
            if ($a =~ /\A-([omn])\z/ && defined $args[$i + 1]) { $opt{$1} = $args[++$i]; }
            elsif ($a =~ /\A-([omn])(.+)\z/) { $opt{$1} = $2; }
        }
        push @found, { pid => $pid, device => $opt{o} || 'default', mac => $opt{m}, name => $opt{n} };
    }
    closedir $dh;
    return @found;
}

# ALSA device string -> /proc/asound card directory name ("card1").
sub _cardFor {
    my ($device) = @_;
    $device = '' unless defined $device;
    if ($device =~ /CARD=([^,:\s]+)/i || $device =~ /\A(?:plug)?(?:hw|sysdefault|front|iec958|default):([A-Za-z_]\w*)/) {
        my $want = $1;
        for my $dir (glob '/proc/asound/card[0-9]*') {
            my $id = _readLine("$dir/id");
            return (split m{/}, $dir)[-1] if defined $id && $id eq $want;
        }
        return;
    }
    return "card$1" if $device =~ /\A(?:plug)?hw:(\d+)/;
    # "default" or an alias: if exactly one card is playing besides the
    # Loopback, that's it.
    my @playing = grep { _hwParams((split m{/}, $_)[-1]) && (_readLine("$_/id") || '') ne 'Loopback' }
        glob '/proc/asound/card[0-9]*';
    return @playing == 1 ? (split m{/}, $playing[0])[-1] : undef;
}

# Product name from /proc/asound/cards, e.g. "FiiO K11 R2R" for
# " 1 [R2R            ]: USB-Audio - FiiO K11 R2R".
sub _longName {
    my ($card) = @_;
    my ($num) = $card =~ /(\d+)\z/ or return;
    for my $line (split /\n/, _slurp('/proc/asound/cards')) {
        next unless $line =~ /\A\s*$num\s+\[[^\]]*\]:.*?\s-\s(.+?)\s*\z/;
        return $1;
    }
    return;
}

sub _hwParams {
    my ($card) = @_;
    for my $file (glob "/proc/asound/$card/pcm*p/sub*/hw_params") {
        my $text = _slurp($file);
        next if $text !~ /\S/ || $text =~ /\Aclosed/;
        my ($format) = $text =~ /^format:\s*(\S+)/m;
        my ($rate)   = $text =~ /^rate:\s*(\d+)/m;
        return ($format, $rate) if $format && $rate;
    }
    return;
}

sub _depth {
    my ($format) = @_;
    return 'float' if $format =~ /FLOAT/;
    return "$1-bit" if $format =~ /\A[SU](\d+)/;
    return $format;
}

sub _khz {
    my ($rate) = @_;
    my $k = $rate / 1000;
    return ($k == int($k) ? int($k) : sprintf('%.1f', $k)) . ' kHz';
}

sub _isLocalIp {
    my ($ip) = @_;
    return 0 unless $ip;
    my $route = _slurp('/proc/net/fib_trie');
    return index($route, "|-- $ip\n") >= 0 && $route =~ /\Q|-- $ip\E\n\s+\/32 host LOCAL/ ? 1 : 0;
}

sub _readLine { my $s = _slurp($_[0]); $s =~ s/\s+\z//; return length $s ? $s : undef; }
sub _slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $s = <$fh>; close $fh; return defined $s ? $s : ''; }

1;
