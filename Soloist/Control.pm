package Plugins::Soloist::Control;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1);
use JSON::XS qw(encode_json);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::Soloist::Metadata;

my $prefs = preferences('plugin.soloist');
my $log = logger('plugin.soloist');
my $lastError = '';
sub lastError { return $lastError; }

# Short-lived loopback WebSocket client. The socket is restricted to localhost;
# no remote control port is exposed by this plugin.
sub send {
    my ($class, $command, $extra) = @_;
    $lastError = '';
    return _fail("Unsupported Soloist command: $command")
        unless $command =~ /\A(?:play|pause|skip_next|skip_prev|seek)\z/;
    my %payload = (type => 'command', command => $command);
    if (ref($extra) eq 'HASH') {
        $payload{$_} = $extra->{$_} for keys %{$extra};
    }
    # Prefer the persistent metadata connection: no handshake, no blocking.
    if (Plugins::Soloist::Metadata->can('sendPayload')
        && Plugins::Soloist::Metadata->sendPayload(\%payload)) {
        $log->debug("Command sent to Soloist: $command");
        return 1;
    }
    my ($host, $port) = split /:/, ($prefs->get('wsAddress') || '127.0.0.1:9878'), 2;
    $host = '127.0.0.1' unless $host eq '127.0.0.1' || $host eq 'localhost';
    $port = 9878 unless $port && $port =~ /^\d+$/ && $port < 65536;
    my $sock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 1);
    return _fail("Cannot connect to Soloist WebSocket at $host:$port") unless $sock;
    $sock->autoflush(1);
    my $rawKey = _randomBytes(16);
    my $key = encode_base64($rawKey, '');
    print {$sock} "GET / HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nOrigin: http://127.0.0.1\r\n\r\n";
    my $headers = '';
    my $select = IO::Select->new($sock);
    while (length($headers) < 8192 && $headers !~ /\r\n\r\n\z/) {
        last unless $select->can_read(1);
        my $char;
        my $n = sysread($sock, $char, 1);
        last unless $n;
        $headers .= $char;
    }
    my $accept = encode_base64(sha1($key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
    unless ($headers =~ m{\AHTTP/1\.[01] 101\b} && $headers =~ /^Sec-WebSocket-Accept:\s*\Q$accept\E\s*$/im) {
        close $sock;
        return _fail('Soloist WebSocket handshake was rejected');
    }
    my $json = encode_json(\%payload);
    my $frame = _maskedTextFrame($json);
    my $offset = 0;
    while ($offset < length $frame) {
        my $n = syswrite($sock, $frame, length($frame) - $offset, $offset);
        unless ($n) { close $sock; return _fail('Could not send Soloist command'); }
        $offset += $n;
    }
    close $sock;
    $log->debug("Command sent to Soloist (one-shot connection): $command");
    return 1;
}

sub _maskedTextFrame {
    my ($payload) = @_;
    my $len = length $payload;
    my $head = pack('C', 0x81);
    if ($len < 126) { $head .= pack('C', 0x80 | $len); }
    elsif ($len < 65536) { $head .= pack('C n', 0x80 | 126, $len); }
    else { $head .= pack('C N', 0x80 | 127, 0, $len); }
    my $mask = _randomBytes(4);
    my $masked = '';
    for my $i (0 .. $len - 1) { $masked .= substr($payload, $i, 1) ^ substr($mask, $i % 4, 1); }
    return $head . $mask . $masked;
}
sub _randomBytes {
    my ($n) = @_;
    my $out = '';
    if (open my $fh, '<', '/dev/urandom') {
        sysread($fh, $out, $n);
        close $fh;
    }
    $out .= pack('C', int(rand(256))) while length($out) < $n;
    return substr($out, 0, $n);
}
sub _fail { $lastError = $_[0]; $log->warn($lastError); return 0; }

1;
