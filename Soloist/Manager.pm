package Plugins::Soloist::Manager;

use strict;
use warnings;
use POSIX qw(_exit setsid dup2 WNOHANG);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec;
use IO::Socket::INET;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes ();

my $prefs = preferences('plugin.soloist');
my $log = logger('plugin.soloist');

use constant START_TIMEOUT => 10;     # seconds to wait for the WebSocket
use constant STOP_TIMEOUT  => 3;      # seconds before TERM escalates to KILL
use constant LOG_MAX_BYTES => 1_000_000;
use constant LOG_TAIL_BYTES => 16_384;

my $lastError = '';
my $phase = 'idle';          # idle | starting | stopping
my $childPid = 0;            # pid we forked (needs reaping)
my $phasePid = 0;
my $deadline = 0;
my $killSent = 0;
my $startAfterStop = 0;

sub lastError { return $lastError; }

# Soloist lives in <base>/bin/soloist; pid file and log go in <base>.
sub _paths {
    my $bin = $prefs->get('soloistPath') || '';
    my $binDir = dirname($bin);
    my $base = basename($binDir) eq 'bin' ? dirname($binDir) : $binDir;
    return (
        bin  => $bin,
        base => $base,
        argv => './' . File::Spec->abs2rel($bin, $base),
        pid  => "$base/soloist.pid",
        log  => "$base/soloist.log",
    );
}

sub status {
    _reap();
    my %p = _paths();
    my $pid = _readPid($p{pid});
    unless (_isOurPid($pid)) {
        $pid = _findSoloistPid();
        _writeFile($p{pid}, "$pid\n", 0600) if $pid;
    }
    return {
        running  => $pid ? 1 : 0,
        pid      => $pid || 0,
        starting => $phase eq 'starting' ? 1 : 0,
        stopping => $phase eq 'stopping' ? 1 : 0,
    };
}

sub start {
    $lastError = '';
    return 1 if $phase eq 'starting';
    if ($phase eq 'stopping') { $startAfterStop = 1; return 1; }
    return 1 if status()->{running};

    my %p = _paths();
    my $bin = $p{bin};
    my $keyPath = $prefs->get('apiKeyFile') || '';
    return _fail('Soloist executable path must be absolute') unless $bin =~ m{\A/};
    return _fail("Soloist executable is missing or not executable: $bin") unless -f $bin && -x _;
    return _fail('API key file is missing or unreadable') unless -f $keyPath && -r _;
    my @keyStat = stat $keyPath;
    return _fail('API key file must have private permissions (chmod 600)') if @keyStat && ($keyStat[2] & 0077);
    my $key = _readFile($keyPath);
    $key =~ s/\A\s+|\s+\z//g;
    return _fail('API key file is empty') unless length $key;

    my $device = $prefs->get('playbackDevice') || '';
    if ($device =~ /Loopback/i && -r '/proc/asound/cards' && _readFile('/proc/asound/cards') !~ /Loopback/) {
        return _fail('ALSA Loopback card is not present (is snd-aloop loaded?)');
    }

    for my $dir ($prefs->get('dataDir'), $prefs->get('cacheDir')) {
        return _fail('Data/cache directory path is empty') unless defined $dir && length $dir;
        eval { make_path($dir) unless -d $dir; 1 } or return _fail("Cannot create directory $dir: $@");
    }

    # Keep the log from growing without bound on the SD card.
    if (-f $p{log} && -s _ > LOG_MAX_BYTES) {
        rename $p{log}, "$p{log}.1";
    }
    open my $logfh, '>>', $p{log}
        or return _fail("Cannot open Soloist log $p{log}: $!");
    select((select($logfh), $| = 1)[0]);
    print {$logfh} "\n--- Soloist launch requested " . localtime() . " ---\n";

    my $pid = fork();
    unless (defined $pid) {
        close $logfh;
        return _fail("fork failed: $!");
    }
    if (!$pid) {
        # Match the known-good SSH launch context: start in the install
        # directory and give Soloist the same relative argv[0].
        chdir($p{base}) or _exit(126);
        $ENV{PWD} = $p{base};
        # LMS on piCorePlayer can run with real UID/GID 0 but effective UID/GID
        # tc. If that mismatch reaches exec(), glibc enables secure execution
        # and ignores LD_LIBRARY_PATH, so the Pulse shim is never found. Make
        # the real IDs match the effective ones before exec.
        my $uid = $>;
        my ($gid) = split(/\s+/, $));
        $< = $uid;
        $( = $gid;
        _exit(126) unless $< == $> && $( == $);
        $ENV{USER} = $ENV{LOGNAME} = 'tc';
        $ENV{HOME} = '/home/tc';
        eval { setsid(); };
        umask 077;
        # LMS traps Perl's CORE::open, including STDOUT/STDERR; duplicate the
        # log descriptor directly instead.
        dup2(fileno($logfh), 1) == 1 or _exit(126);
        dup2(fileno($logfh), 2) == 2 or _exit(126);
        $ENV{LD_LIBRARY_PATH} = $prefs->get('shimDir') || '';
        $ENV{APULSE_PLAYBACK_DEVICE} = $device;
        $ENV{APULSE_MAX_TLENGTH_MS} = _number('maxTlengthMs', 500, 50, 5000);
        if ($prefs->get('shimDiagnostics')) { $ENV{APULSE_DIAG} = '1'; }
        else { delete $ENV{APULSE_DIAG}; }
        my @args = (
            $p{argv},
            '--device-name', $prefs->get('deviceName') || 'Soloist Connect',
            '--api-key', $key,
            '--data-dir', $prefs->get('dataDir'),
            '--cache-dir', $prefs->get('cacheDir'),
            '--ws', $prefs->get('wsAddress') || '127.0.0.1:9878',
            '--initial-volume', _number('initialVolume', 100, 0, 100),
            '--cache-size', _number('cacheSize', 100, 0, 10000),
        );
        exec { $bin } @args or do {
            print STDERR "Could not execute Soloist at $bin: $!\n";
            _exit(127);
        };
    }
    close $logfh;
    $childPid = $pid;
    unless (_writeFile($p{pid}, "$pid\n", 0600)) {
        kill 'TERM', $pid;
        return _fail("Could not write Soloist pid file $p{pid}: $!");
    }

    # Don't block the LMS main loop: poll for the WebSocket on a timer.
    $phase = 'starting';
    $phasePid = $pid;
    $deadline = Time::HiRes::time() + START_TIMEOUT;
    _setTimer(0.2, \&_checkStarted);
    $log->info("Launched Soloist pid=$pid, waiting for its WebSocket");
    return 1;
}

sub _checkStarted {
    return unless $phase eq 'starting';
    _reap();
    my %p = _paths();
    unless (_alive($phasePid)) {
        $phase = 'idle';
        unlink $p{pid};
        my $detail = _lastLines(5);
        _fail('Soloist exited during startup' . ($detail ? "; last log: $detail" : ''));
        return;
    }
    if (_websocketReady()) {
        $phase = 'idle';
        $log->info("Soloist pid=$phasePid is ready");
        return;
    }
    if (Time::HiRes::time() > $deadline) {
        $phase = 'idle';
        kill 'TERM', $phasePid;
        unlink $p{pid};
        my $detail = _lastLines(5);
        _fail('Soloist did not open its WebSocket within ' . START_TIMEOUT . ' s'
            . ($detail ? "; last log: $detail" : ''));
        _setTimer(1, \&_reap);
        return;
    }
    _setTimer(0.2, \&_checkStarted);
}

sub stop {
    $lastError = '';
    $startAfterStop = 0;
    if ($phase eq 'starting') {
        Slim::Utils::Timers::killTimers(__PACKAGE__, \&_checkStarted);
        $phase = 'idle';
    }
    return 1 if $phase eq 'stopping';
    my %p = _paths();
    my $state = status();
    unless ($state->{running}) {
        unlink $p{pid};
        return 1;
    }
    kill('TERM', $state->{pid}) or return _fail("Could not signal Soloist pid $state->{pid}: $!");
    $phase = 'stopping';
    $phasePid = $state->{pid};
    $killSent = 0;
    $deadline = Time::HiRes::time() + STOP_TIMEOUT;
    _setTimer(0.1, \&_checkStopped);
    $log->info("Sent TERM to Soloist pid=$state->{pid}");
    return 1;
}

sub _checkStopped {
    return unless $phase eq 'stopping';
    _reap();
    my %p = _paths();
    unless (_alive($phasePid)) {
        $phase = 'idle';
        unlink $p{pid};
        $log->info("Soloist pid=$phasePid has exited");
        if ($startAfterStop) {
            $startAfterStop = 0;
            start();
        }
        return;
    }
    if (Time::HiRes::time() > $deadline) {
        if (!$killSent) {
            $log->warn("Soloist pid=$phasePid ignored TERM; sending KILL");
            kill 'KILL', $phasePid;
            $killSent = 1;
            $deadline = Time::HiRes::time() + 2;
        }
        else {
            $phase = 'idle';
            $startAfterStop = 0;
            _fail("Soloist pid $phasePid did not exit");
            return;
        }
    }
    _setTimer(0.1, \&_checkStopped);
}

sub restart {
    $lastError = '';
    if (status()->{running} || $phase eq 'stopping') {
        stop();
        $startAfterStop = 1;
        return 1;
    }
    return start();
}

sub logTail {
    my %p = _paths();
    open my $fh, '<', $p{log} or return '';
    my $size = -s $fh || 0;
    my $from = $size > LOG_TAIL_BYTES ? $size - LOG_TAIL_BYTES : 0;
    seek($fh, $from, 0);
    local $/;
    my $text = <$fh> // '';
    close $fh;
    $text =~ s/\A[^\n]*\n// if $from;     # drop the partial first line
    my @lines = split /\n/, $text;
    @lines = splice(@lines, -30) if @lines > 30;
    return join "\n", @lines;
}

sub _lastLines {
    my ($n) = @_;
    my @lines = grep { /\S/ } split /\n/, logTail();
    @lines = splice(@lines, -$n) if @lines > $n;
    return join(' | ', @lines);
}

# ---------------------------------------------------------------------------

sub _setTimer {
    my ($delay, $code) = @_;
    Slim::Utils::Timers::killTimers(__PACKAGE__, $code);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + $delay, $code);
}

# Collect our forked child once it exits so it doesn't linger as a zombie
# (a zombie still answers kill 0 and still reports comm "soloist").
sub _reap {
    return unless $childPid;
    my $r = waitpid($childPid, WNOHANG);
    if ($r == $childPid) {
        $log->info("Soloist pid=$childPid exited with status " . ($? >> 8));
        $childPid = 0;
    }
    elsif ($r == -1) {
        $childPid = 0;    # already reaped elsewhere, or not our child
    }
}

sub _alive {
    my ($pid) = @_;
    return 0 unless $pid && kill(0, $pid);
    my $stat = _readFile("/proc/$pid/stat");
    return 0 if $stat =~ /\)\s+([ZX])\s/;
    return 1;
}

sub _number {
    my ($name, $default, $min, $max) = @_;
    my $v = $prefs->get($name);
    $v = $default unless defined $v && $v =~ /^\d+$/ && $v >= $min && $v <= $max;
    return int($v);
}

sub _isOurPid {
    my ($pid) = @_;
    return 0 unless _alive($pid);
    my $exe = readlink("/proc/$pid/exe") || '';
    $exe =~ s/ \(deleted\)\z//;
    my $configured = $prefs->get('soloistPath') || '';
    return 1 if length($configured) && $exe eq $configured;
    # piCorePlayer's /proc exe link can report a normalized mount path that
    # differs from the saved path; the comm name still identifies Soloist.
    my $comm = _readFile("/proc/$pid/comm");
    $comm =~ s/\s+\z//;
    return $comm eq 'soloist' ? 1 : 0;
}

sub _findSoloistPid {
    opendir my $dh, '/proc' or return 0;
    my @pids = grep { /^\d+$/ } readdir $dh;
    closedir $dh;
    for my $pid (sort { $a <=> $b } @pids) {
        return int($pid) if _isOurPid($pid);
    }
    return 0;
}

sub _readPid { my $s = _readFile($_[0]); return $s =~ /^(\d+)/ ? int($1) : 0; }

sub _websocketReady {
    my ($host, $port) = split /:/, ($prefs->get('wsAddress') || '127.0.0.1:9878'), 2;
    $host = '127.0.0.1' unless $host eq '127.0.0.1' || $host eq 'localhost';
    $port = 9878 unless $port && $port =~ /^\d+$/ && $port < 65536;
    my $socket = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 0.2);
    return 0 unless $socket;
    close $socket;
    return 1;
}

sub _readFile { my ($path) = @_; open my $fh, '<', $path or return ''; local $/; return <$fh> // ''; }

sub _writeFile {
    my ($path, $data, $mode) = @_;
    open my $fh, '>', $path or return 0;
    chmod $mode, $path;
    print {$fh} $data;
    close $fh;
    return 1;
}

sub _fail { $lastError = $_[0]; $log->error($lastError); return 0; }

1;
