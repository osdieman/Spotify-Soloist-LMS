package Plugins::Soloist::LogWriter;

# Appends lines to soloist.log without ever blocking LMS.
#
# soloist.log lives on the SD card. A plain open/print/close from inside LMS
# can wait for seconds when the card is busy, and the stall watchdog showed
# exactly that. Instead, lines go into a pipe to a small "cat >> soloist.log"
# process: that process does the (possibly slow) disk writes. The pipe is
# non-blocking; if it is ever full, the line is dropped rather than waiting.
#
# The cat process is double-forked so it belongs to init and never needs
# reaping. It exits by itself when the pipe is closed (reopen/stop).

use strict;
use warnings;

use POSIX ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Slim::Utils::Log;

my $log = logger('plugin.soloist');

my $pipe;           # write end
my $pipePath = '';  # file the current cat appends to
my $dropped = 0;
my $lastSpawnFail = 0;

sub write {
    my ($class, $text) = @_;
    return 0 unless defined $text && length $text;
    require Plugins::Soloist::Manager;
    my $path = Plugins::Soloist::Manager->logPath();
    return 0 unless $path && $path =~ m{\A/[^\x00-\x1f]+\z};

    _close() if $pipe && $path ne $pipePath;
    unless ($pipe) {
        # Don't fork again and again if something is wrong.
        return 0 if time() - $lastSpawnFail < 30;
        _spawn($path) or do { $lastSpawnFail = time(); return 0; };
    }

    if ($dropped) {
        $text = "--- ($dropped log line(s) dropped: log writer was busy)\n" . $text;
    }
    local $SIG{PIPE} = 'IGNORE';
    my $n = syswrite($pipe, $text);
    if (!defined $n) {
        if ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR) {
            $dropped++;
            return 0;
        }
        _close();      # cat is gone; respawn on the next line
        $dropped++;
        return 0;
    }
    # A partial write only happens when the pipe is nearly full; the rest of
    # this text is lost, which is acceptable for a diagnostics log.
    $dropped = 0;
    return 1;
}

# The log file was rotated (renamed): start a new cat on the new file.
sub reopen { _close(); }
sub stop   { _close(); }

sub _close {
    close $pipe if $pipe;
    undef $pipe;
    $pipePath = '';
}

sub _spawn {
    my ($path) = @_;
    my ($r, $w);
    unless (pipe($r, $w)) {
        $log->warn("Soloist log writer: pipe failed: $!");
        return 0;
    }
    my $pid = fork();
    unless (defined $pid) {
        $log->warn("Soloist log writer: fork failed: $!");
        close $r; close $w;
        return 0;
    }
    if (!$pid) {
        # First child: fork again and leave, so cat is reparented to init.
        my $pid2 = fork();
        POSIX::_exit(0) if !defined $pid2 || $pid2;
        eval { POSIX::setsid(); };
        close $w;
        POSIX::dup2(fileno($r), 0) == 0 or POSIX::_exit(126);
        # Nothing to say on stdout/stderr; send them to /dev/null.
        if (open my $null, '+<', '/dev/null') {
            POSIX::dup2(fileno($null), 1);
            POSIX::dup2(fileno($null), 2);
        }
        exec('/bin/sh', '-c', 'exec cat >> "$0"', $path) or POSIX::_exit(127);
    }
    close $r;
    waitpid($pid, 0);
    my $flags = fcntl($w, F_GETFL, 0);
    fcntl($w, F_SETFL, $flags | O_NONBLOCK) if defined $flags;
    $pipe = $w;
    $pipePath = $path;
    return 1;
}

1;
