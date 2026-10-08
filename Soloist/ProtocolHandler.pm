package Plugins::Soloist::ProtocolHandler;

# soloist: source. Captures the ALSA Loopback that the Pulse shim plays into
# and hands it to LMS as a live, non-seekable remote stream. Replaces the
# WaveInput plugin: same Pipeline approach, but with our own capture format
# (S24_3LE -> FLAC), an explicit arecord buffer, and Soloist metadata served
# directly from getMetadataFor (no wrapping of another plugin's method).
#
# The transcoding rules live in custom-convert.conf next to this file; the
# content type "sol" (URL prefix "soloist:") is declared in custom-types.conf.
# This module only fills in $FILE$ (the capture device) and then applies the
# buffer and diagnostics settings to the command LMS selected.

use strict;
use warnings;
use base qw(Slim::Player::Pipeline);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.soloist');
my $prefs = preferences('plugin.soloist');

use constant URL            => 'soloist:connect';
use constant CONTENT_TYPE   => 'sol';
use constant DEFAULT_DEVICE => 'plughw:CARD=Loopback,DEV=1,SUBDEV=0';
use constant DEFAULT_BUFFER_MS => 2000;
use constant PERIOD_US      => 50_000;

sub captureDevice {
    my $device = $prefs->get('captureDevice') || '';
    return $device =~ /\A[\w:=,.\-]+\z/ ? $device : DEFAULT_DEVICE;
}

sub captureBufferMs {
    my $ms = $prefs->get('captureBufferMs');
    return defined $ms && $ms =~ /^\d+$/ && $ms >= 200 && $ms <= 4000 ? int($ms) : DEFAULT_BUFFER_MS;
}

sub new {
    my ($class, $args) = @_;
    my $transcoder = $args->{transcoder};
    my $url        = $args->{url};
    my $client     = $args->{client};

    unless ($transcoder) {
        $log->error("No transcoding rule for $url; is custom-convert.conf in the plugin folder, and was LMS restarted?");
        return;
    }

    Plugins::Soloist::Watchdog->mark('start capture pipeline')
        if Plugins::Soloist::Watchdog->can('mark');
    Slim::Music::Info::setContentType($url, CONTENT_TYPE);
    _endStaleCapture(captureDevice());
    Plugins::Soloist::Plugin->captureStarted($client) if Plugins::Soloist::Plugin->can('captureStarted');
    my $quality = preferences('server')->client($client)->get('lameQuality');
    my $command = Slim::Player::TranscodingHelper::tokenizeConvertCommand2(
        $transcoder, captureDevice(), $url, 1, $quality);
    $command = _tuneCommand($command);
    $log->info("Soloist capture: $command");

    my $self = $class->SUPER::new(undef, $command);
    unless ($self) {
        $log->error('Could not start the Soloist capture pipeline');
        return;
    }
    ${*$self}{contentType} = $transcoder->{streamformat};
    return $self;
}

# Apply the buffer setting, and when audio diagnostics are on, append
# arecord's stderr (overrun!!! lines) to the Soloist log.
sub _tuneCommand {
    my ($command) = @_;
    my $bufferUs = captureBufferMs() * 1000;
    my $periodUs = PERIOD_US < $bufferUs / 4 ? PERIOD_US : int($bufferUs / 4);
    $command =~ s/--buffer-time=\d+/--buffer-time=$bufferUs/;
    $command =~ s/--period-time=\d+/--period-time=$periodUs/;

    return $command unless $prefs->get('shimDiagnostics');
    require Plugins::Soloist::Manager;
    my $logPath = Plugins::Soloist::Manager->logPath();
    return $command unless $logPath && $logPath =~ m{\A/[^'\x00-\x1f]+\z};

    require Plugins::Soloist::LogWriter;
    Plugins::Soloist::LogWriter->write('--- capture start ' . localtime()
        . " (buffer ${bufferUs}us, period ${periodUs}us) ---\n");
    my ($capture, $rest) = split /\s\|\s/, $command, 2;
    $capture .= " 2>>'$logPath'";
    return defined $rest ? "$capture | $rest" : $capture;
}

# An arecord left over from an earlier stream keeps the Loopback capture
# open, and the new one then fails with "Device or resource busy" (silence).
# End any arecord of ours that is still recording from the same device.
# The newest stream wins: two unsynced players can't share one capture.
sub _endStaleCapture {
    my ($device) = @_;
    my @stale;
    opendir my $dh, '/proc' or return;
    for my $pid (grep { /\A\d+\z/ } readdir $dh) {
        next if $pid == $$;
        my @st = stat "/proc/$pid";
        next unless @st && $st[4] == $>;                     # ours only
        my $stat = _slurp("/proc/$pid/stat");
        next unless $stat =~ /\A\d+\s+\(arecord\)\s+([^ZX])/;
        my $cmd = _slurp("/proc/$pid/cmdline");
        next unless index($cmd, "\0$device\0") >= 0 || $cmd =~ /\0-D\Q$device\E\0/;
        push @stale, $pid;
    }
    closedir $dh;
    return unless @stale;
    $log->warn('Ending stale capture arecord pid ' . join(', ', @stale)
        . " (still holding $device)");
    kill 'TERM', @stale;
    # Give them a moment to release the device before our arecord opens it.
    # This only happens when a stale capture exists, and lasts at most 0.5 s.
    for (1 .. 25) {
        @stale = grep { -e "/proc/$_" && _slurp("/proc/$_/stat") !~ /\)\s+[ZX]\s/ } @stale;
        last unless @stale;
        select(undef, undef, undef, 0.02);
    }
    kill 'KILL', @stale if @stale;
}

sub _slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $s = <$fh>; return defined $s ? $s : ''; }

sub isRemote { 1 }
sub isAudioURL { 1 }
sub canDirectStream { 0 }
sub canHandleTranscode { 1 }
sub canSeek { 0 }
sub canDoAction { 1 }

sub contentType {
    my $self = shift;
    return ${*$self}{contentType};
}

sub getStreamBitrate {
    my ($self, $maxRate) = @_;
    return Slim::Player::Song::guessBitrateFromFormat(${*$self}{contentType}, $maxRate);
}

sub scanUrl {
    my ($class, $url, $args) = @_;
    Slim::Utils::Scanner::Remote->scanURL($url, $args);
}

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my $format = $client ? (eval { $client->streamingSong()->streamformat() } || '') : '';
    # Spotify delivers decoded float audio of unknown original depth; what we
    # can state is the transport format, and for a squeezelite on this same
    # machine the live format at its DAC (read from ALSA).
    my $transport = $format eq 'flc' ? 'FLAC 24-bit/44.1 kHz'
        : $format eq 'pcm' ? 'PCM 16-bit/44.1 kHz' : '';
    my $dac;
    if ($transport && $client) {
        require Plugins::Soloist::Output;
        $dac = Plugins::Soloist::Output->describe($client);
    }
    my %result = (
        title => 'Soloist Connect',
        type  => 'Spotify (Soloist Connect)',
        ($transport ? (bitrate => join(" \x{2192} ", 'Spotify', $transport, ($dac ? $dac : ()))) : ()),
    );

    my $meta = Plugins::Soloist::Plugin->sourceMetadata($client, $url);
    if (ref($meta) eq 'HASH') {
        @result{qw(title artist album duration)} = @{$meta}{qw(title artist album duration)};
        if ($meta->{cover}) {
            $result{cover} = $meta->{cover};
            $result{icon}  = $meta->{cover};
        }
    }
    return \%result;
}

1;
