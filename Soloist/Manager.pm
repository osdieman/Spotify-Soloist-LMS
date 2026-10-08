package Plugins::Soloist::Manager;

use strict;
use warnings;
use POSIX qw(_exit setsid dup2 WNOHANG);
use POSIX ();
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec;
use IO::Socket::INET;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Cwd ();
use MIME::Base64 qw(decode_base64);
use JSON::XS ();
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
use constant HELPER_TERM_WAIT => 2;    # seconds before helpers get KILL

my $lastError = '';
my $phase = 'idle';          # idle | starting | stopping
my $childPid = 0;            # pid we forked (needs reaping)
my $phasePid = 0;
my $deadline = 0;
my $killSent = 0;
my $startAfterStop = 0;
my $phaseSid = 0;            # session of the Soloist being stopped
my $stage = '';              # stopping: main | helpers
my %helperTermed;            # pid => 1 once TERM was sent

sub lastError { return $lastError; }
sub logPath { my %p = _paths(); return $p{log}; }

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
        helpers  => [ map { _procInfo($_) || { pid => $_ } } _relatedPids($pid) ],
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

    # Leftovers of an earlier Soloist (e.g. its helper, reparented to init)
    # can hold the audio device or the WebSocket port.
    if (my @stale = _relatedPids(0)) {
        _terminate('stale Soloist process', @stale);
        Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + HELPER_TERM_WAIT,
            \&_killSurvivors, @stale);
    }

    for my $dir ($prefs->get('dataDir'), $prefs->get('cacheDir')) {
        return _fail('Data/cache directory path is empty') unless defined $dir && length $dir;
        eval { make_path($dir) unless -d $dir; 1 } or return _fail("Cannot create directory $dir: $@");
    }

    # Keep the log from growing without bound on the SD card.
    if (-f $p{log} && -s _ > LOG_MAX_BYTES) {
        rename $p{log}, "$p{log}.1";
        # The log writer's cat still appends to the renamed file; restart it.
        require Plugins::Soloist::LogWriter;
        Plugins::Soloist::LogWriter->reopen();
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
    %helperTermed = ();
    unless ($state->{running}) {
        unlink $p{pid};
        # Nothing to stop, but orphaned helpers of an earlier run may remain.
        return 1 unless @{ $state->{helpers} };
        $phaseSid = 0;
        _beginStopping(0, 'helpers');
        return 1;
    }
    my $info = _procInfo($state->{pid}) || {};
    # We start Soloist with setsid(), so it leads its own session. Anything
    # else in that session belongs to it. Never use our own session.
    my $ownSid = (_procInfo($$) || {})->{sid} || -1;
    $phaseSid = ($info->{sid} && $info->{sid} == $state->{pid} && $info->{sid} != $ownSid) ? $info->{sid} : 0;
    kill('TERM', $state->{pid}) or return _fail("Could not signal Soloist pid $state->{pid}: $!");
    _beginStopping($state->{pid}, 'main');
    $log->info("Sent TERM to Soloist pid=$state->{pid}");
    return 1;
}

sub _beginStopping {
    my ($pid, $firstStage) = @_;
    $phase = 'stopping';
    $stage = $firstStage;
    $phasePid = $pid;
    $killSent = 0;
    $deadline = Time::HiRes::time() + STOP_TIMEOUT;
    _setTimer(0.1, \&_checkStopped);
}

sub _checkStopped {
    return unless $phase eq 'stopping';
    Plugins::Soloist::Watchdog->mark('Soloist stop check') if Plugins::Soloist::Watchdog->can('mark');
    _reap();
    my %p = _paths();

    if ($stage eq 'main') {
        if (_alive($phasePid)) {
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
            return;
        }
        unlink $p{pid};
        $log->info("Soloist pid=$phasePid has exited");
        $stage = 'helpers';
        $killSent = 0;
        $deadline = Time::HiRes::time() + HELPER_TERM_WAIT;
    }

    # Soloist's own helper can outlive it (reparented to init, PPid 1).
    my @left = _relatedPids($phasePid, $phaseSid);
    if (@left) {
        my @new = grep { !$helperTermed{$_} } @left;
        if (@new) {
            _terminate('Soloist helper', @new);
            $helperTermed{$_} = 1 for @new;
            $deadline = Time::HiRes::time() + HELPER_TERM_WAIT unless $killSent;
        }
        if (Time::HiRes::time() > $deadline) {
            if (!$killSent) {
                $log->warn('Soloist helper(s) ignored TERM; sending KILL to pid ' . join(', ', @left));
                kill 'KILL', @left;
                $killSent = 1;
                $deadline = Time::HiRes::time() + 1;
            }
            else {
                $log->warn('Soloist helper(s) still present after KILL: pid ' . join(', ', @left));
                @left = ();
            }
        }
        if (@left) {
            _setTimer(0.1, \&_checkStopped);
            return;
        }
    }

    $phase = 'idle';
    $stage = '';
    %helperTermed = ();
    if ($startAfterStop) {
        $startAfterStop = 0;
        start();
    }
}

sub _terminate {
    my ($what, @pids) = @_;
    for my $pid (@pids) {
        my $info = _procInfo($pid) || {};
        $log->warn("Ending $what pid=$pid (ppid=" . ($info->{ppid} // '?') . ', '
            . ($info->{comm} // '?') . ')');
        kill 'TERM', $pid;
    }
}

sub _killSurvivors {
    my ($class, @pids) = @_;
    my @alive = grep { _alive($_) } @pids;
    return unless @alive;
    $log->warn('Stale Soloist process(es) ignored TERM; sending KILL to pid ' . join(', ', @alive));
    kill 'KILL', @alive;
}

sub restart {
    $lastError = '';
    my $state = status();
    if ($state->{running} || @{ $state->{helpers} } || $phase eq 'stopping') {
        stop();
        $startAfterStop = 1;
        return 1;
    }
    return start();
}

sub logTail {
    my ($class, $max) = @_;
    $max = 30 unless defined $max && $max =~ /\A\d+\z/;
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
    @lines = splice(@lines, -$max) if @lines > $max;
    return join "\n", @lines;
}

sub _lastLines {
    my ($n) = @_;
    my @lines = grep { /\S/ } split /\n/, logTail(undef, 30);
    @lines = splice(@lines, -$n) if @lines > $n;
    return join(' | ', @lines);
}

# ---------------------------------------------------------------------------
# API key file. The key is written here and read at launch; it never goes
# into LMS preferences, the settings page or the LMS log.

sub keyPath { return $prefs->get('apiKeyFile') || ''; }

sub saveKey {
    my ($class, $key, $path) = @_;
    $lastError = '';
    $path = keyPath() unless defined $path && length $path;
    return _fail('API key file path must be absolute') unless $path =~ m{\A/};
    $key = '' unless defined $key;
    $key =~ s/\A\s+|\s+\z//g;
    return _fail('The API key is empty') unless length $key;
    return _fail('The API key contains spaces or control characters') if $key =~ /[\s\x00-\x1f\x7f]/;
    return _fail('The API key is too long') if length($key) > 8192;

    my $dir = dirname($path);
    unless (-d $dir) {
        eval { make_path($dir, { mode => 0700 }); 1 }
            or return _fail("Cannot create folder $dir: $@");
    }
    my $tmp = "$path.new.$$";
    unlink $tmp;
    my $old = umask 077;
    my $ok = sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600);
    umask $old;
    return _fail("Cannot write $tmp: $!") unless $ok;
    my $written = syswrite($fh, "$key\n");
    unless (close($fh) && defined $written && $written == length($key) + 1) {
        unlink $tmp;
        return _fail("Could not write the API key file: $!");
    }
    chmod 0600, $tmp;
    unless (rename $tmp, $path) {
        my $err = $!;
        unlink $tmp;
        return _fail("Cannot replace $path: $err");
    }
    chmod 0600, $path;
    $log->warn("Soloist API key file updated ($path)");
    return 1;
}

# What the settings page shows about the key: never the key itself.
sub keyStatus {
    my $path = keyPath();
    my %s = (path => $path);
    unless (length $path && -e $path) { $s{state} = 'missing'; return \%s; }
    my @st = stat $path;
    $s{changed} = @st ? POSIX::strftime('%Y-%m-%d %H:%M', localtime($st[9])) : '';
    unless (-r _) { $s{state} = 'unreadable'; return \%s; }
    if (@st && ($st[2] & 0077)) {
        $s{state} = 'permissions';
        $s{mode} = sprintf('%04o', $st[2] & 07777);
    }
    my $key = _readFile($path);
    $key =~ s/\A\s+|\s+\z//g;
    unless (length $key) { $s{state} = 'empty'; return \%s; }
    $s{state} ||= 'ok';
    $s{tail} = length($key) > 8 ? substr($key, -4) : '';
    if (my $exp = _keyExpiry($key)) {
        $s{expires}  = POSIX::strftime('%Y-%m-%d', localtime($exp));
        $s{daysLeft} = int(($exp - time()) / 86400);
        $s{expired}  = $exp <= time() ? 1 : 0;
    }
    return \%s;
}

# If the key is a JWT with an "exp" claim, that is its expiry. Other key
# formats carry no readable date.
sub _keyExpiry {
    my ($key) = @_;
    return unless $key =~ /\A[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]*\z/;
    (my $b64 = $1) =~ tr/-_/+\//;
    $b64 .= '=' x ((4 - length($b64) % 4) % 4);
    my $claims = eval { JSON::XS::decode_json(decode_base64($b64)) };
    return unless ref $claims eq 'HASH';
    my $exp = $claims->{exp};
    return defined $exp && $exp =~ /\A\d{9,11}\z/ ? $exp : undef;
}

# Lines from the latest Soloist run that point at an expired or rejected
# key/licence. Empty when nothing like that was logged.
sub expiryHint {
    my $tail = logTail(undef, 80);
    my $at = rindex($tail, '--- Soloist launch requested');
    $tail = substr($tail, $at) if $at >= 0;
    my @hits = grep {
        /\bexpired\b|licen[cs]e\W+(?:has\W+)?(?:expired|invalid|revoked)|unauthori[sz]ed|(?:invalid|revoked)\W+(?:api\W*)?key|api\W*key\W+(?:is\W+)?(?:invalid|revoked|expired)/i
    } split /\n/, $tail;
    @hits = @hits[-3 .. -1] if @hits > 3;
    return join("\n", @hits);
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

sub _allPids {
    opendir my $dh, '/proc' or return ();
    my @pids = sort { $a <=> $b } map { int } grep { /^\d+$/ } readdir $dh;
    closedir $dh;
    return @pids;
}

# Soloist's helper can also be called "soloist". The real Soloist is the one
# we started with setsid(), so prefer a session leader.
sub _findSoloistPid {
    my @found = grep { $_ != $$ && _isOurPid($_) } _allPids();
    return 0 unless @found;
    for my $pid (@found) {
        my $info = _procInfo($pid) or next;
        return $pid if $info->{sid} == $pid;
    }
    return $found[0];
}

sub _procInfo {
    my ($pid) = @_;
    my $stat = _readFile("/proc/$pid/stat");
    return unless $stat =~ /\A\d+\s+\((.*)\)\s+(\S)\s+(\d+)\s+(\d+)\s+(\d+)/s;
    return { pid => $pid, comm => $1, state => $2, ppid => $3, pgrp => $4, sid => $5 };
}

sub _exeOf {
    my ($pid) = @_;
    my $exe = readlink("/proc/$pid/exe");
    return '' unless defined $exe;
    $exe =~ s/ \(deleted\)\z//;
    return $exe;
}

# Processes that belong to Soloist other than $mainPid: members of its
# session/process group, anything running from the Soloist install folder,
# and other processes named "soloist". Never LMS itself.
sub _relatedPids {
    my ($mainPid, $sid) = @_;
    $mainPid ||= 0;
    my $ownInfo = _procInfo($$) || {};
    if (!defined $sid && $mainPid) {
        my $info = _procInfo($mainPid) || {};
        $sid = ($info->{sid} && $info->{sid} == $mainPid) ? $mainPid : 0;
    }
    $sid = 0 if $sid && $ownInfo->{sid} && $sid == $ownInfo->{sid};

    # Folder test only for a dedicated Soloist folder: with a binary in e.g.
    # /usr/local/bin the "base" would be /usr/local, which also holds
    # squeezelite and other things that must never be touched.
    my %p = _paths();
    my %seen;
    my @bins = grep { length && !$seen{$_}++ }
        ($p{bin}, scalar(eval { Cwd::abs_path($p{bin}) } || ''));
    my @bases = grep { length && basename($_) =~ /soloist/i && !$seen{$_}++ }
        ($p{base}, scalar(eval { Cwd::abs_path($p{base}) } || ''));

    my @out;
    for my $pid (_allPids()) {
        next if $pid == $$ || $pid == $mainPid || $pid <= 1;
        next if $ownInfo->{pgrp} && $pid == $ownInfo->{pgrp};
        my $info = _procInfo($pid) or next;
        next if $info->{state} eq 'Z' || $info->{state} eq 'X';
        my $match = 0;
        $match = 1 if $sid && ($info->{sid} == $sid || $info->{pgrp} == $sid);
        unless ($match) {
            my $exe = _exeOf($pid);
            $match = 1 if length $exe
                && (grep({ $exe eq $_ } @bins) || grep({ index($exe, "$_/") == 0 } @bases));
        }
        $match = 1 if !$match && $info->{comm} eq 'soloist';
        push @out, $pid if $match;
    }
    return @out;
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
