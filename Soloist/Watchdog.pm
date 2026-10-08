package Plugins::Soloist::Watchdog;

# Stall watchdog for the LMS main loop.
#
# LMS is single-threaded: while any timer, request or plugin callback runs,
# nothing else does, including reading the soloist: capture pipe. If that
# lasts longer than the arecord buffer, arecord overruns and audio drops out.
#
# A short timer (TICK) measures how late it fires. A tick that is more than
# THRESHOLD late means the main loop was blocked; that is written to
# soloist.log with the duration, the CPU picture during the stall and the
# last thing this plugin did before it.
#
# In "call stack" mode a one-shot SIGALRM (setitimer) is armed on every tick.
# It only fires if the next tick does not arrive in time, i.e. only during a
# stall, and records the Perl call stack at that moment: that names the code
# LMS was stuck in. The handler is a deferred (safe) Perl signal handler
# installed with SA_RESTART, so blocking reads/writes are restarted by the
# kernel and are not cut short; the stack is taken at the first Perl
# statement boundary, which is still inside the code that caused the stall.
#
# The watchdog also follows soloist.log: every arecord "overrun!!!" line gets
# a timestamped annotation saying whether an LMS stall preceded it.

use strict;
use warnings;

use POSIX ();
use Scalar::Util qw(refaddr);
use Time::HiRes ();
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $prefs = preferences('plugin.soloist');
my $log   = logger('plugin.soloist');

use constant TICK            => 0.25;   # s between ticks
use constant THRESHOLD       => 0.5;    # s late before a tick counts as a stall
use constant SAMPLE_INTERVAL => 1.0;    # s between further stack samples in one stall
use constant MAX_SAMPLES     => 4;
use constant MAX_FRAMES      => 14;
use constant LOG_SCAN_EVERY  => 4;      # ticks (= 1 s)
use constant STALL_MEMORY    => 15;     # s an overrun looks back for a stall
use constant MAX_SCAN_BYTES  => 65_536;

my $running = 0;
my $mode = 0;              # 1 = duration only, 2 = with call stack
my $nextDue;               # monotonic time the next tick is due
my $tickCount = 0;
my ($lastCpu, $lastMajflt, $lastSys);
my $clkTck;

my ($markLabel, $markAt) = ('', 0);   # last plugin activity (monotonic)

my $alarmInstalled = 0;
my $oldAlarmAction;
my @samples;               # [monotonic time, stack text] taken during a stall

my @recentStalls;          # [end monotonic, duration, wall time string]
my $logOffset;             # bytes of soloist.log already scanned
my $logPathSeen = '';
my $stallCount = 0;
my $lastStallText = '';

# ---------------------------------------------------------------------------

sub _mono {
    my $t = eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) };
    return defined $t ? $t : Time::HiRes::time();
}

sub _wallStamp {
    my $now = Time::HiRes::time();
    return POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime($now))
        . sprintf('.%03d', ($now - int($now)) * 1000);
}

# Cheap breadcrumb for "what was running just before". Call from plugin
# timers and event handlers.
sub mark {
    my ($class, $label) = @_;
    $markLabel = $label;
    $markAt = _mono();
}

sub status {
    return {
        mode   => $running ? $mode : 0,
        stalls => $stallCount,
        last   => $lastStallText,
    };
}

sub start {
    my ($class) = @_;
    my $wanted = $prefs->get('stallWatchdog');
    $wanted = 2 unless defined $wanted && $wanted =~ /\A[012]\z/;
    $class->stop() if $running;
    return unless $wanted;

    $mode = $wanted;
    $running = 1;
    $nextDue = undef;          # first tick only sets the baseline
    $tickCount = 0;
    @samples = ();
    $logOffset = undef;
    _installAlarm() if $mode == 2;
    _schedule();
    $log->info('Soloist stall watchdog started (' . ($mode == 2 ? 'with call stack' : 'duration only') . ')');
}

sub stop {
    my ($class) = @_;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_tick);
    _disarm();
    _removeAlarm();
    $running = 0;
}

# ---------------------------------------------------------------------------

sub _schedule {
    $nextDue = _mono() + TICK;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_tick);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + TICK, \&_tick);
    _arm(TICK + THRESHOLD) if $mode == 2;
}

sub _tick {
    return unless $running;
    my $now = _mono();
    my $due = $nextDue;
    my ($cpu, $majflt) = _selfStat();
    my $sys = _sysStat();

    if (defined $due) {
        my $late = $now - $due;
        if ($late > THRESHOLD) {
            _reportStall($late, $due, $cpu, $majflt, $sys);
        }
    }
    @samples = ();
    ($lastCpu, $lastMajflt, $lastSys) = ($cpu, $majflt, $sys);

    $tickCount++;
    if ($tickCount % LOG_SCAN_EVERY == 0) {
        eval { _scanLog(); 1 } or $log->debug("Watchdog log scan failed: $@");
    }
    # Another module may have replaced or localised SIGALRM (Slim::Formats::XML
    # does, around XMLin) and on restore Perl drops SA_RESTART. Re-assert ours
    # about once a second.
    _installAlarm() if $mode == 2 && $tickCount % 4 == 0;
    _schedule();
}

sub _reportStall {
    my ($late, $due, $cpu, $majflt, $sys) = @_;
    $stallCount++;
    my $stamp = _wallStamp();
    my @facts;

    if (defined $cpu && defined $lastCpu) {
        my $used = $cpu - $lastCpu;
        push @facts, sprintf('LMS CPU %.2f s (%s)', $used,
            $used > 0.6 * ($late + TICK) ? 'busy computing' : 'mostly waiting');
    }
    push @facts, 'major page faults +' . ($majflt - $lastMajflt)
        if defined $majflt && defined $lastMajflt && $majflt > $lastMajflt;
    if ($sys && $lastSys) {
        my $total = $sys->{total} - $lastSys->{total};
        if ($total > 0) {
            push @facts, sprintf('system busy %d%%, iowait %d%%',
                100 * ($total - ($sys->{idle} - $lastSys->{idle}) - ($sys->{iowait} - $lastSys->{iowait})) / $total,
                100 * ($sys->{iowait} - $lastSys->{iowait}) / $total);
        }
    }
    if (open my $fh, '<', '/proc/loadavg') {
        my ($load) = split /\s+/, (scalar <$fh> || '');
        close $fh;
        push @facts, "load $load" if defined $load;
    }

    my $activity = 'none recorded';
    if ($markLabel) {
        my $before = $due - $markAt;
        $activity = $before >= 0
            ? sprintf('%s, %.2f s before the stall', $markLabel, $before)
            : sprintf('%s, during the stall', $markLabel);
    }

    my $summary = sprintf('LMS main loop blocked %.2f s', $late);
    my $text = "--- stall $stamp: $summary (" . join(', ', @facts) . ")\n"
        . "    last Soloist plugin activity: $activity\n";
    if (@samples) {
        my %seen;
        my $i = 0;
        for my $sample (@samples) {
            $i++;
            next if $seen{$sample->[1]}++;
            my $at = $sample->[0] - $due;
            $text .= sprintf("    call stack at +%.1f s%s:\n", $at,
                @samples > 1 ? " (sample $i of " . scalar(@samples) . ')' : '');
            $text .= join('', map { "      $_\n" } split /\n/, $sample->[1]);
        }
    }
    elsif ($mode == 2) {
        $text .= "    call stack: not captured (SIGALRM was in use elsewhere or did not fire)\n";
    }

    $lastStallText = $text;
    push @recentStalls, [_mono(), $late, $stamp];
    shift @recentStalls while @recentStalls > 20;
    _appendLog($text);
    $log->warn("Soloist watchdog: $summary; details in soloist.log");
}

# ---------------------------------------------------------------------------
# SIGALRM stack sampling

sub _onAlarm {
    return unless $running && $mode == 2;
    my @lines;
    # Frame 0 is this handler (its call site is the interrupted statement),
    # frame 1 is the eval wrapper Perl puts around safe handlers.
    my @here = caller(0);
    push @lines, 'at ' . _shortPath($here[1]) . ':' . $here[2] if @here;
    for (my $i = 1; @lines < MAX_FRAMES; $i++) {
        my @c = caller($i) or last;
        next if $c[3] eq '(eval)' && $i == 1;
        push @lines, "in $c[3] (called at " . _shortPath($c[1]) . ":$c[2])";
    }
    push @samples, [_mono(), join("\n", @lines)];
    _arm(SAMPLE_INTERVAL) if @samples < MAX_SAMPLES;
}

sub _installAlarm {
    my $current = $SIG{ALRM};
    # Someone else's handler is active right now (e.g. a localised one):
    # leave SIGALRM alone; _arm() will not arm until ours is back.
    return 0 if ref $current && !_ours();
    return 0 if defined $current && !ref $current
        && $current !~ /\A(?:|DEFAULT|IGNORE)\z/;
    my $action = POSIX::SigAction->new(\&_onAlarm, POSIX::SigSet->new, POSIX::SA_RESTART());
    $action->safe(1);
    my $old = POSIX::SigAction->new;
    unless (POSIX::sigaction(POSIX::SIGALRM(), $action, $old)) {
        $log->warn("Watchdog could not install SIGALRM handler: $!; call stacks disabled");
        $mode = 1;
        return 0;
    }
    $oldAlarmAction = $old unless $alarmInstalled;
    $alarmInstalled = 1;
    return 1;
}

sub _removeAlarm {
    return unless $alarmInstalled;
    my $current = $SIG{ALRM};
    if (ref $current && refaddr($current) == refaddr(\&_onAlarm)) {
        if ($oldAlarmAction) { POSIX::sigaction(POSIX::SIGALRM(), $oldAlarmAction); }
        else { $SIG{ALRM} = 'DEFAULT'; }
    }
    $alarmInstalled = 0;
    $oldAlarmAction = undef;
}

sub _ours {
    my $current = $SIG{ALRM};
    return ref $current && refaddr($current) == refaddr(\&_onAlarm) ? 1 : 0;
}

sub _arm {
    my ($seconds) = @_;
    # Never arm SIGALRM unless our handler is the one that will run: the
    # default action of SIGALRM would terminate LMS.
    return unless $alarmInstalled && _ours();
    eval { Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), $seconds); 1 };
}

sub _disarm {
    return unless $alarmInstalled && _ours();
    eval { Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 0); 1 };
}

sub _shortPath {
    my ($path) = @_;
    return '?' unless defined $path;
    $path =~ s{\A.*/(?=(?:Slim|Plugins)/)}{};
    $path =~ s{\A.*/(?:perl5?|lib)/(?:[\d.]+/)?(?:[\w-]+-linux[\w-]*/)?}{};
    return $path;
}

# ---------------------------------------------------------------------------
# /proc readings

sub _selfStat {
    open my $fh, '<', '/proc/self/stat' or return;
    my $line = <$fh>;
    close $fh;
    return unless defined $line && $line =~ /\)\s+(.*)\z/s;
    my @f = split /\s+/, $1;
    # after "comm)": state=0 ... majflt=7 utime=11 stime=12
    $clkTck ||= eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
    return (($f[11] + $f[12]) / $clkTck, $f[7]);
}

sub _sysStat {
    open my $fh, '<', '/proc/stat' or return;
    my $line = <$fh>;
    close $fh;
    return unless defined $line && $line =~ /\Acpu\s+(.*)/;
    my @f = split /\s+/, $1;
    my $total = 0;
    $total += $_ for grep { /\A\d+\z/ } @f[0 .. ($#f < 7 ? $#f : 7)];
    return { total => $total, idle => $f[3] || 0, iowait => $f[4] || 0 };
}

# ---------------------------------------------------------------------------
# soloist.log

sub _logPath {
    require Plugins::Soloist::Manager;
    my $path = Plugins::Soloist::Manager->logPath();
    return $path && $path =~ m{\A/} ? $path : undef;
}

sub _appendLog {
    my ($text) = @_;
    my $path = _logPath() or return;
    open my $fh, '>>', $path or return;
    print {$fh} $text;
    close $fh;
    # Our own lines may be scanned again later; they never contain
    # arecord's "overrun!!!", so they are not mistaken for overruns.
}

sub _scanLog {
    my $path = _logPath() or return;
    my $size = -s $path;
    $size = 0 unless defined $size;    # not created yet: everything is new
    if (!defined $logOffset || $path ne $logPathSeen) {
        # First look at this file: only new lines from now on count.
        $logPathSeen = $path;
        $logOffset = $size;
        return;
    }
    $logOffset = 0 if $size < $logOffset;     # rotated at a Soloist start
    return if $size == $logOffset;

    my $from = $logOffset;
    $from = $size - MAX_SCAN_BYTES if $size - $from > MAX_SCAN_BYTES;
    open my $fh, '<', $path or return;
    seek($fh, $from, 0);
    local $/;
    my $chunk = <$fh> // '';
    close $fh;
    $logOffset = $size;

    my @overruns = $chunk =~ /^(.*overrun!!!.*)$/mg;
    return unless @overruns;

    my $now = _mono();
    my @stalls = grep { $now - $_->[0] <= STALL_MEMORY } @recentStalls;
    my $text = '';
    for my $line (@overruns) {
        my ($lost) = $line =~ /at least\s+([\d.]+)\s*ms/;
        my $what = '--- overrun seen ' . _wallStamp()
            . (defined $lost ? " (arecord lost at least $lost ms)" : '');
        if (@stalls) {
            my $s = $stalls[-1];
            $what .= sprintf(': preceded by an LMS stall of %.2f s at %s', $s->[1], $s->[2]);
        }
        elsif ($running) {
            $what .= sprintf(': no LMS main-loop stall over %.1f s in the %d s before it'
                . ' (LMS was not blocked; look at the player/buffer side)', THRESHOLD, STALL_MEMORY);
        }
        $text .= "$what\n";
    }
    _appendLog($text);
}

1;
