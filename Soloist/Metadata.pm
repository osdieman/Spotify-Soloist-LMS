package Plugins::Soloist::Metadata;

# Persistent loopback WebSocket client for Soloist state/metadata events.
# Everything is non-blocking and driven by LMS's select loop: the TCP connect,
# the HTTP upgrade handshake, reads and writes. Nothing here waits for
# Soloist, so a slow or hung Soloist can never stall LMS (0.1.27 and earlier
# waited up to 1 s per handshake byte and per blocked write). A 1 s timer
# requests fresh state (position sync). Control.pm sends transport commands
# over this connection.

use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1);
use JSON::XS qw(encode_json decode_json);
use Slim::Networking::Select;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes ();
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Socket qw(SOL_SOCKET SO_ERROR);
use Plugins::Soloist::Watchdog ();

my $prefs = preferences('plugin.soloist');
my $log = logger('plugin.soloist');

use constant STATE_INTERVAL => 1;
use constant MAX_BUFFER     => 2_000_000;
use constant MAX_FRAME      => 1_000_000;
use constant MAX_OUTPUT     => 262_144;
use constant HANDSHAKE_TIMEOUT => 3;

my $wanted = 0;
my $socket;              # open and upgraded
my $pending;             # connecting or handshaking
my $pendingStage = '';   # connect | handshake
my $handshakeKey = '';
my $handshakeIn = '';
my $output = '';         # bytes not yet accepted by the kernel
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
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_handshakeTimeout);
    _abortPending();
    _closeSocket();
}

sub isConnected { return $socket ? 1 : 0; }

# Ask for a reconnect attempt soon (used by Control when it finds no socket).
sub kick {
    return unless $wanted && !$socket && !$pending;
    $retryDelay = 2;
    _scheduleConnect(0.1);
}

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

sub _retryLater {
    _scheduleConnect($retryDelay);
    $retryDelay = $retryDelay < 30 ? $retryDelay * 2 : 30;
}

sub _tryConnect {
    return unless $wanted;
    return if $socket || $pending;
    Plugins::Soloist::Watchdog->mark('Soloist WebSocket connect');
    my ($host, $port) = _address();
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Blocking => 0,
    );
    unless ($sock) {
        $log->debug("Soloist WebSocket connect failed ($!); retrying in ${retryDelay}s");
        _retryLater();
        return;
    }
    $pending = $sock;
    $pendingStage = 'connect';
    $handshakeIn = '';
    $output = '';
    Slim::Networking::Select::addWrite($sock, \&_onConnectWritable);
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_handshakeTimeout);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + HANDSHAKE_TIMEOUT, \&_handshakeTimeout);
}

sub _onConnectWritable {
    return unless $pending && $pendingStage eq 'connect';
    Slim::Networking::Select::removeWrite($pending);
    my $err = getsockopt($pending, SOL_SOCKET, SO_ERROR);
    $err = defined $err ? unpack('i', $err) : 1;
    if ($err) {
        $log->debug("Soloist WebSocket connect failed (error $err); retrying in ${retryDelay}s");
        _abortPending();
        _retryLater();
        return;
    }
    my ($host, $port) = _address();
    $handshakeKey = encode_base64(_randomBytes(16), '');
    $pendingStage = 'handshake';
    Slim::Networking::Select::addRead($pending, \&_onHandshakeReadable);
    _queue($pending, "GET / HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        . "Sec-WebSocket-Key: $handshakeKey\r\nSec-WebSocket-Version: 13\r\nOrigin: http://127.0.0.1\r\n\r\n")
        or do { _abortPending(); _retryLater(); };
}

sub _onHandshakeReadable {
    return unless $pending && $pendingStage eq 'handshake';
    my $chunk = '';
    my $n = sysread($pending, $chunk, 8192);
    if (!defined $n) {
        return if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
    }
    if (!$n) {
        _abortPending();
        _retryLater();
        return;
    }
    $handshakeIn .= $chunk;
    my $end = index($handshakeIn, "\r\n\r\n");
    if ($end < 0) {
        if (length($handshakeIn) > 8192) { _abortPending(); _retryLater(); }
        return;
    }
    my $headers = substr($handshakeIn, 0, $end + 4);
    my $rest = substr($handshakeIn, $end + 4);
    my $accept = encode_base64(sha1($handshakeKey . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
    unless ($headers =~ m{\AHTTP/1\.[01] 101\b}
        && $headers =~ /^Sec-WebSocket-Accept:\s*\Q$accept\E\s*$/im) {
        $log->debug('Soloist WebSocket handshake rejected');
        _abortPending();
        _retryLater();
        return;
    }

    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_handshakeTimeout);
    Slim::Networking::Select::removeRead($pending);
    $socket = $pending;
    $pending = undef;
    $pendingStage = '';
    $handshakeIn = '';
    $input = $rest;
    $fragment = '';
    $fragmentOpcode = 0;
    Slim::Networking::Select::addRead($socket, \&_onReadable);
    Slim::Networking::Select::addWrite($socket, \&_onWritable) if length $output;
    $retryDelay = 2;
    $log->info('Soloist WebSocket connected');
    Plugins::Soloist::Plugin->soloistConnectionChanged(1);
    if (length $input && !_parseFrames()) { _disconnected(); return; }
    _requestState();
}

sub _handshakeTimeout {
    return unless $pending;
    $log->debug('Soloist WebSocket handshake timed out');
    _abortPending();
    _retryLater();
}

sub _abortPending {
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_handshakeTimeout);
    if ($pending) {
        Slim::Networking::Select::removeRead($pending);
        Slim::Networking::Select::removeWrite($pending);
        close $pending;
    }
    undef $pending;
    $pendingStage = '';
    $handshakeIn = '';
    $output = '';
}

sub _requestState {
    return unless $socket;
    Plugins::Soloist::Watchdog->mark('Soloist get_state request');
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

sub _onReadable {
    return unless $socket;
    Plugins::Soloist::Watchdog->mark('Soloist WebSocket read');
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
    return _queue($socket, $frame . $mask . _xorMask($payload, $mask));
}

sub _xorMask {
    my ($data, $mask) = @_;
    my $len = length $data;
    return '' unless $len;
    my $full = substr($mask x (int($len / 4) + 1), 0, $len);
    return $data ^ $full;
}

# Never blocks: whatever the kernel doesn't take now is kept in $output and
# flushed when the socket becomes writable. Returns 0 on a hard error or
# when Soloist has stopped reading for so long that the backlog is too big.
sub _queue {
    my ($sock, $data) = @_;
    $output .= $data;
    return 0 if length($output) > MAX_OUTPUT;
    return _flush($sock);
}

sub _flush {
    my ($sock) = @_;
    local $SIG{PIPE} = 'IGNORE';
    while (length $output) {
        my $n = syswrite($sock, $output);
        if (!defined $n) {
            if ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR) {
                Slim::Networking::Select::addWrite($sock,
                    ($socket && $sock == $socket) ? \&_onWritable : \&_onPendingWritable);
                return 1;
            }
            return 0;
        }
        substr($output, 0, $n, '');
    }
    Slim::Networking::Select::removeWrite($sock);
    return 1;
}

sub _onPendingWritable {
    return unless $pending && $pendingStage eq 'handshake';
    unless (_flush($pending)) { _abortPending(); _retryLater(); }
}

sub _onWritable {
    return unless $socket;
    _disconnected() unless _flush($socket);
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
        Slim::Networking::Select::removeWrite($socket);
        close $socket;
    }
    undef $socket;
    $input = '';
    $output = '';
    $fragment = '';
    $fragmentOpcode = 0;
}

1;
