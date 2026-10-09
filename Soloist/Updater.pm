package Plugins::Soloist::Updater;

# Keeps the Soloist binary current. Soloist builds stop working 90 days after
# their build date (exit code 10). Spotify publishes the current build under a
# fixed URL per architecture and asks that it is downloaded from there, not
# redistributed; this module downloads it on this machine only.
#
#   check      HEAD request; nothing is downloaded unless the archive changed
#              and is newer than the installed build
#   download   in the background (LMS's async HTTP, streamed to a file)
#   unpack     tar in a background shell, polled
#   test       the new binary must run "--version", report the same
#              architecture and a newer build than the installed one
#   install    rename into place; the previous binary stays as "<bin>.prev"
#   restart    only when no player has played the Soloist source for a while
#              (immediately when the installed build has expired)
#   verify     if the new build doesn't start, the previous one is restored

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use POSIX ();
use Time::HiRes ();
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('plugin.soloist');
my $prefs = preferences('plugin.soloist');

use constant LIFETIME      => 90 * 86400;    # Spotify: builds expire 90 days after the build date
use constant FIRST_CHECK   => 300;           # s after LMS start
use constant CHECK_EVERY   => 24 * 3600;
use constant RETRY_AFTER   => 3600;          # after a failed check or download
use constant IDLE_NEEDED   => 600;           # s without Soloist playback before restarting
use constant IDLE_POLL     => 30;
use constant VERIFY_AFTER  => 90;            # s after the restart
use constant UNPACK_WAIT   => 180;
use constant SAME_BUILD    => 6 * 3600;      # archive uploaded within this of the build = same build

my %URL = (
    aarch64 => 'https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz',
    armv7l  => 'https://soloist-builds.spotifycdn.com/soloist_release_arm32.tar.gz',
    x86_64  => 'https://soloist-builds.spotifycdn.com/soloist_release_x86_64.tar.gz',
);

my $phase = 'idle';    # idle checking downloading unpacking waiting verifying
my $message = '';
my $lastCheck;
my %pending;           # what is being downloaded/installed
my %infoCache;         # path -> [mtime, size, info]
my $idleSince;

sub status {
    return { phase => $phase, message => $message, lastCheck => $lastCheck };
}

sub init {
    _timer(FIRST_CHECK, sub { __PACKAGE__->check() });
}

# Installed build, read from "soloist --version":
# "soloist 1.3.9.3 build 1791525725 (20261009) (g440165f200) (linux/aarch64)"
sub binInfo {
    my ($class, $path) = @_;
    $path ||= $prefs->get('soloistPath') || '';
    return unless length $path && -f $path && -x _;
    my @st = stat _;
    my $c = $infoCache{$path};
    return $c->[2] if $c && $c->[0] == $st[9] && $c->[1] == $st[7];
    my $info = _version($path);
    $infoCache{$path} = [$st[9], $st[7], $info];
    return $info;
}

sub _version {
    my ($path) = @_;
    return if $path =~ /'/;
    my $out = `'$path' --version 2>&1`;
    return unless $? == 0 && defined $out;
    my ($version, $built, $arch) = $out =~ /soloist\s+(\S+)\s+build\s+(\d{9,11})\b.*?\(linux\/([\w-]+)\)/s
        or return;
    return {
        version => $version,
        built   => $built,
        arch    => $arch,
        expires => $built + LIFETIME,
        daysLeft => int(($built + LIFETIME - time()) / 86400),
    };
}

# One line for the settings page.
sub buildText {
    my ($class) = @_;
    my $i = $class->binInfo() or return '';
    return sprintf('%s, built %s, expires %s (%d days left)', $i->{version},
        POSIX::strftime('%Y-%m-%d', localtime($i->{built})),
        POSIX::strftime('%Y-%m-%d', localtime($i->{expires})), $i->{daysLeft});
}

sub check {
    my ($class, $force) = @_;
    return 0 if $phase ne 'idle';
    unless ($force || $prefs->get('autoUpdate')) {
        _timer(CHECK_EVERY, sub { __PACKAGE__->check() });
        return 0;
    }
    my $bin = $prefs->get('soloistPath') || '';
    my $info = $class->binInfo($bin);
    my $arch = $info ? $info->{arch} : (POSIX::uname())[4];
    my $url = $URL{$arch} or return _done("No Soloist build is published for this architecture ($arch).");
    return _done("The Soloist folder is not writable: " . dirname($bin)) unless length $bin && -w dirname($bin);

    $phase = 'checking';
    $message = 'Checking for a new Soloist build…';
    $lastCheck = time();
    require Slim::Networking::SimpleAsyncHTTP;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub { _checked(shift, $url, $bin, $info) },
        sub { _done("Update check failed: $_[1]", RETRY_AFTER) },
        { timeout => 30 },
    )->head($url);
    return 1;
}

sub _checked {
    my ($http, $url, $bin, $info) = @_;
    my $h = $http->headers;
    my $etag = $h ? ($h->header('ETag') || '') : '';
    my $size = $h ? ($h->header('Content-Length') || 0) : 0;
    my $modified = $h ? ($h->last_modified || 0) : 0;
    return _done('Update check failed: HTTP ' . ($http->code // '?'), RETRY_AFTER)
        unless ($http->code // 0) == 200;

    return _done('The latest Soloist build failed here before; keeping the current one.')
        if length $etag && $etag eq ($prefs->get('updateBadEtag') || '');
    my $same = length $etag && $etag eq ($prefs->get('updateEtag') || '');
    if (!$same && $info && $modified && $modified < $info->{built} + SAME_BUILD) {
        $prefs->set('updateEtag', $etag) if length $etag;
        $same = 1;
    }
    if ($same) {
        return _done('Soloist has expired and Spotify has not published a newer build yet; checking again in an hour.', RETRY_AFTER)
            if $info && $info->{daysLeft} < 0;
        return _done('Soloist is up to date.');
    }

    my $dir = _updateDir($bin);
    eval { make_path($dir); 1 } or return _done("Cannot create $dir: $@", RETRY_AFTER);
    my $archive = "$dir/soloist.tar.gz";
    unlink "$archive.part";
    %pending = (bin => $bin, etag => $etag, size => $size, archive => $archive, old => $info);
    $phase = 'downloading';
    $message = sprintf('Downloading a new Soloist build (%.1f MB)…', $size / 1e6);
    $log->info("Soloist update: downloading $url");
    Slim::Networking::SimpleAsyncHTTP->new(
        \&_downloaded,
        sub { unlink "$archive.part"; _done("Download failed: $_[1]", RETRY_AFTER) },
        { timeout => 600, saveAs => "$archive.part" },
    )->get($url);
}

sub _downloaded {
    my ($http) = @_;
    my $archive = $pending{archive};
    my $got = -s "$archive.part" || 0;
    unless (($http->code // 0) == 200 && $got > 0 && (!$pending{size} || $got == $pending{size})) {
        unlink "$archive.part";
        return _done(sprintf('Download incomplete (%d of %d bytes)', $got, $pending{size} || 0), RETRY_AFTER);
    }
    rename "$archive.part", $archive or return _done("Cannot rename the download: $!", RETRY_AFTER);

    my $stage = dirname($archive) . '/new';
    remove_tree($stage);
    make_path($stage);
    return _done('Unsafe path for unpacking', RETRY_AFTER) if "$archive$stage" =~ /'/;
    # busybox tar can unpack gzip; run it in the background so LMS never waits.
    system("(tar -xzf '$archive' -C '$stage' && echo ok || echo fail) > '$stage.done' 2>/dev/null &");
    $pending{stage} = $stage;
    $pending{unpackStarted} = time();
    $phase = 'unpacking';
    $message = 'Unpacking the new Soloist build…';
    _timer(1, \&_pollUnpack);
}

sub _pollUnpack {
    my $stage = $pending{stage};
    my $done = -s "$stage.done" ? _read("$stage.done") : '';
    unless ($done) {
        return _timer(1, \&_pollUnpack) if time() - $pending{unpackStarted} < UNPACK_WAIT;
        return _cleanup('Unpacking took too long.', RETRY_AFTER);
    }
    unlink "$stage.done";
    return _cleanup('Unpacking the archive failed.', RETRY_AFTER) unless $done =~ /ok/;

    my ($new) = grep { -f $_ } ("$stage/soloist", glob("$stage/*/soloist"));
    return _cleanup('The archive contains no "soloist" executable.', RETRY_AFTER) unless $new;
    chmod 0755, $new;
    my $info = _version($new);
    return _cleanup('The new Soloist build does not run here ("--version" failed).', 0, 1) unless $info;

    my $old = $pending{old};
    if ($old && $info->{arch} ne $old->{arch}) {
        return _cleanup("The new build is for $info->{arch}, not $old->{arch}.", 0, 1);
    }
    if ($old && $info->{built} <= $old->{built}) {
        $prefs->set('updateEtag', $pending{etag}) if length $pending{etag};
        return _cleanup('Soloist is up to date.');
    }
    _install($new, $info);
}

sub _install {
    my ($new, $info) = @_;
    my $bin = $pending{bin};
    my $old = $pending{old};
    # Same filesystem: renames are atomic and copy nothing. The running Soloist
    # keeps its (now renamed) file until it is restarted.
    unless (rename($new, "$bin.new") && (!-e $bin || rename($bin, "$bin.prev")) && rename("$bin.new", $bin)) {
        my $err = $!;
        rename("$bin.prev", $bin) if !-e $bin && -e "$bin.prev";
        return _cleanup("Installing the new build failed: $err", RETRY_AFTER);
    }
    delete $infoCache{$bin};
    $prefs->set('updateEtag', $pending{etag}) if length $pending{etag};
    my $line = sprintf('--- soloist update %s: %s -> %s (built %s, expires %s)',
        scalar localtime(),
        $old ? "$old->{version} (built " . POSIX::strftime('%Y-%m-%d', localtime($old->{built})) . ')' : 'unknown',
        $info->{version}, POSIX::strftime('%Y-%m-%d', localtime($info->{built})),
        POSIX::strftime('%Y-%m-%d', localtime($info->{expires})));
    $log->warn($line);
    eval { require Plugins::Soloist::LogWriter; Plugins::Soloist::LogWriter->write("$line\n") };
    remove_tree($pending{stage});
    unlink $pending{archive};
    $pending{new} = $info;
    $phase = 'waiting';
    $message = "Soloist $info->{version} is installed; it takes over at the next quiet moment.";
    $idleSince = undef;
    _timer(1, \&_waitForIdle);
}

# Restart only when nobody is listening: no player has played the Soloist
# source for IDLE_NEEDED seconds. If Soloist isn't running (e.g. the old build
# expired), start the new one straight away.
sub _waitForIdle {
    require Plugins::Soloist::Manager;
    require Plugins::Soloist::Plugin;
    my $state = Plugins::Soloist::Manager->status();
    my $now = time();
    if (!$state->{running}) {
        return _restartNow();
    }
    if (Plugins::Soloist::Plugin->sourcePlaying()) {
        $idleSince = undef;
    }
    else {
        $idleSince ||= $now;
        return _restartNow() if $now - $idleSince >= IDLE_NEEDED;
    }
    _timer(IDLE_POLL, \&_waitForIdle);
}

sub _restartNow {
    $log->warn("Restarting Soloist with the new build $pending{new}{version}");
    Plugins::Soloist::Manager->restart();
    $phase = 'verifying';
    $message = "Starting Soloist $pending{new}{version}…";
    _timer(VERIFY_AFTER, \&_verify);
}

sub _verify {
    my $state = Plugins::Soloist::Manager->status();
    if ($state->{running}) {
        my $v = $pending{new}{version};
        %pending = ();
        return _done("Soloist $v is installed and running.");
    }
    # The new build doesn't run: put the previous one back.
    my $bin = $pending{bin};
    $prefs->set('updateBadEtag', $pending{etag}) if length($pending{etag} // '');
    if (-e "$bin.prev") {
        rename($bin, "$bin.failed");
        rename("$bin.prev", $bin);
        delete $infoCache{$bin};
        my $line = '--- soloist update ' . localtime() . ": the new build did not start; restored the previous one";
        $log->error($line);
        eval { Plugins::Soloist::LogWriter->write("$line\n") };
        Plugins::Soloist::Manager->start();
    }
    %pending = ();
    _done('The new Soloist build did not start; the previous build was restored.');
}

# Soloist exited with "build expired": look for a new build right away.
sub expired {
    my ($class) = @_;
    _timer(2, sub { __PACKAGE__->check() }) if $phase eq 'idle';
}

sub _updateDir {
    my ($bin) = @_;
    return dirname(dirname($bin)) . '/update';
}

sub _cleanup {
    my ($msg, $retry, $bad) = @_;
    $prefs->set('updateBadEtag', $pending{etag}) if $bad && length($pending{etag} // '');
    remove_tree($pending{stage}) if $pending{stage};
    unlink $pending{archive} if $pending{archive};
    %pending = ();
    return _done($msg, $retry);
}

sub _done {
    my ($msg, $retry) = @_;
    $phase = 'idle';
    $message = $msg;
    $retry ? $log->warn("Soloist update: $msg") : $log->info("Soloist update: $msg");
    _timer($retry || CHECK_EVERY, sub { __PACKAGE__->check() });
    return 0;
}

sub _timer {
    my ($delay, $code) = @_;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_tick);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + $delay, \&_tick, $code);
}

sub _tick {
    my ($class, $code) = @_;
    eval { $code->(); 1 } or do {
        my $err = $@;
        $log->error("Soloist update: $err");
        _done("Update error: $err", RETRY_AFTER);
    };
}

sub _read { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; return <$fh> // ''; }

1;
