package Plugins::Soloist::Metadata;

# Persistent loopback WebSocket client for Soloist state/metadata events.
# Reads are event-driven through LMS's select loop; a 1 s timer requests
# fresh state (used for position sync). Also used by Control.pm to send
# transport commands without a new handshake when connected.

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1);
use JSON::XS qw(encode_json decode_json);
use Slim::Networking::Select;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

my $prefs = preferences('plugin.soloist');
my $log = logger('plugin.soloist');

use constant STATE_INTERVAL => 1;
use constant MAX_BUFFER     => 2_000_000;
use constant MAX_FRAME      => 1_000_000;

my $wanted = 0;
my $socket;
my $input = '';
my $fragment = '';
my $fragmentOpcode = 0;
my $retryDelay = 2;

sub start {
    $wanted = 1;
    $retryDelay = 2;
    _scheduleConnect(0.1);
}

sub stop {
    $wanted = 0;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_tryConnect);
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_requestState);
    _closeSocket();
}

sub isConnected { return $socket ? 1 : 0; }

# Send a command on the persistent connection. Returns 0 if not connected.
sub sendPayload {
    my ($class, $payload) = @_;
    return 0 unless $socket && ref($payload) eq 'HASH';
    return 1 if _sendFrame(0x1, encode_json($payload));
    _disconnected();
    return 0;
}

sub _scheduleConnect {
    my ($delay) = @_;
    return unless $wanted;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_tryConnect);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + $delay, \&_tryConnect);
}

sub _tryConnect {
    return unless $wanted;
    return if $socket;
    if (_connect()) {
        $retryDelay = 2;
        $log->info('Soloist WebSocket connected');
        Plugins::Soloist::Plugin->soloistConnectionChanged(1);
        _requestState();
        return;
    }
    $log->debug("Soloist WebSocket connect failed; retrying in ${retryDelay}s");
    _scheduleConnect($retryDelay);
    $retryDelay = $retryDelay < 30 ? $retryDelay * 2 : 30;
}

sub _requestState {
    return unless $socket;
    unless (_sendFrame(0x1, encode_json({ type => 'command', command => 'get_state' }))) {
        _disconnected();
        return;
    }
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_requestState);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + STATE_INTERVAL, \&_requestState);
}

sub _address {
    my ($host, $port) = split /:/, ($prefs->get('wsAddress') || '127.0.0.1:9878'), 2;
    $host = '127.0.0.1' unless $host eq '127.0.0.1' || $host eq 'localhost';
    $port = 9878 unless $port && $port =~ /^\d+$/ && $port < 65536;
    return ($host, $port);
}

sub _connect {
    my ($host, $port) = _address();
    my $sock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 1);
    return 0 unless $sock;
    $sock->autoflush(1);

    my $key = encode_base64(_randomBytes(16), '');
    my $request = "GET / HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        . "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nOrigin: http://127.0.0.1\r\n\r\n";
    unless (_writeAll($sock, $request)) { close $sock; return 0; }

    # Read byte-by-byte so no frame data after the headers is consumed.
    my $headers = '';
    my $readable = IO::Select->new($sock);
    while (length($headers) < 8192 && $headers !~ /\r\n\r\n\z/) {
        last unless $readable->can_read(1);
        my $char = '';
        my $n = sysread($sock, $char, 1);
        last unless $n;
        $headers .= $char;
    }
    my $accept = encode_base64(sha1($key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
    unless ($headers =~ m{\AHTTP/1\.[01] 101\b}
        && $headers =~ /^Sec-WebSocket-Accept:\s*\Q$accept\E\s*$/im) {
        close $sock;
        return 0;
    }

    my $flags = fcntl($sock, F_GETFL, 0);
    unless (defined $flags && fcntl($sock, F_SETFL, $flags | O_NONBLOCK)) {
        close $sock;
        return 0;
    }
    $socket = $sock;
    $input = '';
    $fragment = '';
    $fragmentOpcode = 0;
    Slim::Networking::Select::addRead($socket, \&_onReadable);
    return 1;
}

sub _onReadable {
    return unless $socket;
    my $chunk = '';
    my $n = sysread($socket, $chunk, 65536);
    if (!defined $n) {
        _disconnected() unless $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        return;
    }
    if (!$n) {
        _disconnected();
        return;
    }
    $input .= $chunk;
    _disconnected() if length($input) > MAX_BUFFER || !_parseFrames();
}

sub _disconnected {
    my $was = $socket ? 1 : 0;
    _closeSocket();
    if ($was) {
        $log->info('Soloist WebSocket disconnected');
        Plugins::Soloist::Plugin->soloistConnectionChanged(0);
    }
    _scheduleConnect($retryDelay) if $wanted;
}

sub _parseFrames {
    while (length($input) >= 2) {
        my ($first, $second) = unpack('CC', substr($input, 0, 2));
        my $fin = $first & 0x80;
        my $opcode = $first & 0x0f;
        my $masked = $second & 0x80;
        my $length = $second & 0x7f;
        my $offset = 2;
        if ($length == 126) {
            return 1 if length($input) < 4;
            $length = unpack('n', substr($input, 2, 2));
            $offset = 4;
        }
        elsif ($length == 127) {
            return 0;    # Soloist frames never need 64-bit lengths.
        }
        my $mask = '';
        if ($masked) {
            return 1 if length($input) < $offset + 4;
            $mask = substr($input, $offset, 4);
            $offset += 4;
        }
        return 0 if $length > MAX_FRAME;
        return 1 if length($input) < $offset + $length;
        my $payload = substr($input, $offset, $length);
        substr($input, 0, $offset + $length, '');
        $payload = _xorMask($payload, $mask) if $masked;

        if ($opcode == 0x8) { return 0; }
        if ($opcode == 0x9) { _sendFrame(0xA, $payload); next; }
        if ($opcode == 0xA) { next; }
        if ($opcode == 0x1 || $opcode == 0x2) {
            $fragmentOpcode = $opcode;
            $fragment = $payload;
        }
        elsif ($opcode == 0x0 && $fragmentOpcode) {
            $fragment .= $payload;
        }
        else { next; }

        next unless $fin;
        my $message = $fragment;
        my $messageOpcode = $fragmentOpcode;
        $fragment = '';
        $fragmentOpcode = 0;
        next unless $messageOpcode == 0x1;
        my $event = eval { decode_json($message) };
        next unless ref($event) eq 'HASH';
        eval { Plugins::Soloist::Plugin->handleSoloistEvent($event); 1 }
            or $log->warn("Could not apply Soloist event: $@");
    }
    return 1;
}

sub _sendFrame {
    my ($opcode, $payload) = @_;
    return 0 unless $socket;
    my $length = length $payload;
    my $frame = pack('C', 0x80 | $opcode);
    if ($length < 126) { $frame .= pack('C', 0x80 | $length); }
    elsif ($length < 65536) { $frame .= pack('C n', 0x80 | 126, $length); }
    else { return 0; }
    my $mask = _randomBytes(4);
    return _writeAll($socket, $frame . $mask . _xorMask($payload, $mask));
}

sub _xorMask {
    my ($data, $mask) = @_;
    my $len = length $data;
    return '' unless $len;
    my $full = substr($mask x (int($len / 4) + 1), 0, $len);
    return $data ^ $full;
}

sub _writeAll {
    my ($sock, $data) = @_;
    local $SIG{PIPE} = 'IGNORE';
    my $offset = 0;
    my $writable = IO::Select->new($sock);
    while ($offset < length $data) {
        my $n = syswrite($sock, $data, length($data) - $offset, $offset);
        if (!defined $n && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR)) {
            return 0 unless $writable->can_write(1);
            next;
        }
        return 0 unless $n;
        $offset += $n;
    }
    return 1;
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

sub _closeSocket {
    if ($socket) {
        Slim::Networking::Select::removeRead($socket);
        close $socket;
    }
    undef $socket;
    $input = '';
    $fragment = '';
    $fragmentOpcode = 0;
}

1;
