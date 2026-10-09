package Plugins::Soloist::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string);
use Slim::Control::Request;
use Time::HiRes ();
use JSON::XS ();

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.soloist',
    defaultLevel => 'WARN',
    description  => 'PLUGIN_SOLOIST_NAME',
});
my $prefs = preferences('plugin.soloist');
my $metadataCache = Slim::Utils::Cache->new();

my $initialized;
my $activeSourcePlayer;
my $activeSourceClient;
my $originalJumpCommand;
my $originalIndexCommand;
my $jumpInterceptInstalled;
my $lastSoloistMetadata;
my $lastMetadataDiagnosticSignature = '';
my $spotifyPlaying;            # undef = unknown (not yet seen since connect)
my $deviceActive;              # Soloist is_active: undef = unknown
my %lastAppliedMetadataKey;    # per LMS player id
my %sourceStartedAt;
my %lastTransportAt;
my %suppressTransportUntil;
my $autoStartAttempts = 0;
my %appStartedAt;              # per LMS player id: last app-triggered start
my %coverCachedFor;            # url => cover already in the LMS cache
my %captureStartedAt;          # player id => when its capture started
my %lastFlushAt;               # player id => last stream restart
my %pausedAt;                  # player id => when LMS paused the source
my $lastTrackPositionAt = 0;   # time the last position in $lastSoloistMetadata was valid
my $trackStartedAt = 0;        # when Spotify switched to the current track
my $spotifyVolume;             # Soloist volume 0..100, when reported
my %lastErrorLogged;           # Soloist error text => time last logged

use constant SOURCE_URL => 'soloist:connect';

sub initPlugin {
    my ($class) = @_;
    $prefs->init({
        autoStart       => 1,
        soloistPath     => '/mnt/mmcblk0p2/tce/soloist-prototype/bin/soloist',
        shimDir         => '/mnt/mmcblk0p2/tce/soloist-prototype/shim',
        apiKeyFile      => '/mnt/mmcblk0p2/tce/soloist-prototype/api-key',
        playbackDevice  => 'hw:CARD=Loopback,DEV=0,SUBDEV=0',
        deviceName      => 'Soloist Connect',
        dataDir         => '/mnt/mmcblk0p2/tce/soloist-prototype/data',
        # Soloist's audio cache is rewritten constantly; on the SD card it
        # competed with LMS for I/O. /tmp is RAM on piCorePlayer.
        cacheDir        => '/tmp/soloist-cache',
        wsAddress       => '127.0.0.1:9878',
        maxTlengthMs    => 500,
        initialVolume   => 100,
        cacheSize       => 100,
        autoPlayPlayer  => '',
        captureDevice   => 'plughw:CARD=Loopback,DEV=1,SUBDEV=0',
        captureBufferMs => 2000,
        shimDiagnostics => 0,
        stallWatchdog   => 2,      # 0 off, 1 duration, 2 duration + call stack
        appStartsPlayback => 1,
        keepDelayLow    => 1,
        measureSource   => 1,
    });

    require Plugins::Soloist::Watchdog;
    Plugins::Soloist::Watchdog->start();
    $prefs->setChange(sub { Plugins::Soloist::Watchdog->start() }, 'stallWatchdog');

    # Our own soloist: source (replaces WaveInput). Its transcoding rules come
    # from custom-convert.conf / custom-types.conf in this plugin folder.
    require Plugins::Soloist::ProtocolHandler;
    Slim::Player::ProtocolHandlers->registerHandler('soloist', 'Plugins::Soloist::ProtocolHandler');

    # "Soloist Connect" entry under My Apps that starts the source.
    $class->SUPER::initPlugin(
        feed   => \&_feed,
        tag    => 'soloist',
        menu   => 'radios',
        is_app => 1,
        weight => 10,
    );

    require Plugins::Soloist::Settings;
    Plugins::Soloist::Settings->new();

    # LMS Next/Previous must not run LMS's own playlist jump on the single
    # soloist: item: that closes the arecord capture and leaves the player
    # silent until Play is pressed. Intercept the jump and send it to Spotify.
    _installJumpIntercept();

    Slim::Control::Request::subscribe(\&_onNewSong,            [['playlist'], ['newsong']]);
    Slim::Control::Request::subscribe(\&_onPlaylistPause,      [['playlist'], ['pause', 'stop']]);
    Slim::Control::Request::subscribe(\&_onPlayCommand,        [['play']]);
    Slim::Control::Request::subscribe(\&_onSimplePauseCommand, [['pause']]);
    Slim::Control::Request::subscribe(\&_onModeCommand,        [['mode']]);
    $initialized = 1;

    require Plugins::Soloist::Metadata;
    Plugins::Soloist::Metadata->start();

    # Let LMS finish its startup before attempting the standalone daemon.
    $autoStartAttempts = 0;
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 8, \&_autoStart);
    return 1;
}

sub shutdownPlugin {
    my $class = shift;
    return unless $initialized;
    Slim::Control::Request::unsubscribe(\&_onNewSong);
    Slim::Control::Request::unsubscribe(\&_onPlaylistPause);
    Slim::Control::Request::unsubscribe(\&_onPlayCommand);
    Slim::Control::Request::unsubscribe(\&_onSimplePauseCommand);
    Slim::Control::Request::unsubscribe(\&_onModeCommand);
    Slim::Utils::Timers::killTimers($class, \&_autoStart);
    Slim::Utils::Timers::killTimers($class, \&_resumeLmsForSpotify);
    require Plugins::Soloist::Watchdog;
    Plugins::Soloist::Watchdog->stop();
    require Plugins::Soloist::LogWriter;
    Plugins::Soloist::LogWriter->stop();
    _removeJumpIntercept();
    require Plugins::Soloist::Manager;
    Plugins::Soloist::Manager->stop();
    require Plugins::Soloist::Metadata;
    Plugins::Soloist::Metadata->stop();
    $activeSourcePlayer = undef;
    $activeSourceClient = undef;
    $lastSoloistMetadata = undef;
    $lastMetadataDiagnosticSignature = '';
    $spotifyPlaying = undef;
    %lastAppliedMetadataKey = ();
    %sourceStartedAt = ();
    %lastTransportAt = ();
    %suppressTransportUntil = ();
    %appStartedAt = ();
    %coverCachedFor = ();
    %captureStartedAt = ();
    %lastFlushAt = ();
    %pausedAt = ();
    %lastErrorLogged = ();
    $initialized = 0;
}

sub getDisplayName { return 'PLUGIN_SOLOIST_NAME'; }

# ---------------------------------------------------------------------------
# Autostart

sub _autoStart {
    my ($class) = @_;
    return unless $prefs->get('autoStart');
    require Plugins::Soloist::Manager;
    $autoStartAttempts++;
    if (Plugins::Soloist::Manager->start()) {
        $log->info('Soloist autostart requested');
        return;
    }
    # Typical reboot race: snd-aloop or the data partition is not ready yet.
    if ($autoStartAttempts < 6) {
        $log->warn('Soloist autostart failed (' . Plugins::Soloist::Manager->lastError()
            . "); retrying in 15 s (attempt $autoStartAttempts of 6)");
        Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + 15, \&_autoStart);
    }
    else {
        $log->error('Soloist autostart gave up after 6 attempts; see the Soloist settings page');
    }
}

# ---------------------------------------------------------------------------
# Source menu and metadata

# My Apps -> Soloist Connect. Opening the app is the "one tap": the player
# is switched to the Soloist source right away (unless it is busy playing
# something else), and the page shows what is going on plus the controls.
sub _feed {
    my ($client, $callback, $args) = @_;
    Plugins::Soloist::Watchdog->mark('Soloist app menu');
    $client = _masterClient($client);
    my $started = $client && $prefs->get('appStartsPlayback') ? _appAutoStart($client) : '';
    $callback->({ items => _appItems($client, $started) });
}

sub _appItems {
    my ($client, $started) = @_;
    require Plugins::Soloist::Manager;
    my $state = Plugins::Soloist::Manager->status();
    my @items;

    if (!$client) {
        push @items, { name => string('PLUGIN_SOLOIST_APP_NO_PLAYER'), type => 'text' };
    }
    else {
        my $onSource = _isSoloistSource($client);
        my $playing = eval { $client->isPlaying() } ? 1 : 0;
        push @items, {
            name => sprintf(string($onSource && $playing ? 'PLUGIN_SOLOIST_APP_SHOW_PLAYING'
                : $playing ? 'PLUGIN_SOLOIST_APP_SWITCH' : 'PLUGIN_SOLOIST_APP_PLAY'), $client->name),
            type       => 'link',
            url        => \&_appPlay,
            nextWindow => 'nowPlaying',
        };
        push @items, { name => string('PLUGIN_SOLOIST_APP_STARTED'), type => 'text' } if $started eq 'started';
    }

    # Soloist and Spotify status
    my $service = $state->{starting} ? string('PLUGIN_SOLOIST_STARTING')
        : $state->{stopping} ? string('PLUGIN_SOLOIST_STOPPING')
        : $state->{running} ? string('PLUGIN_SOLOIST_RUNNING')
        : string('PLUGIN_SOLOIST_STOPPED');
    $service = string('PLUGIN_SOLOIST_EXPIRED_SHORT') if $state->{expired};
    push @items, { name => string('PLUGIN_SOLOIST_NAME') . ': ' . $service, type => 'text' };
    push @items, { name => _spotifyStatusText($state), type => 'text' };
    if ($client && defined(my $delay = __PACKAGE__->delaySeconds($client))) {
        push @items, { name => sprintf(string('PLUGIN_SOLOIST_DELAY'), $delay), type => 'text' };
    }

    my $key = Plugins::Soloist::Manager->keyStatus();
    if ($key->{state} ne 'ok' && $key->{state} ne 'permissions') {
        push @items, { name => string('PLUGIN_SOLOIST_APP_KEY_PROBLEM'), type => 'text' };
    }
    elsif ($key->{expired}) {
        push @items, { name => sprintf(string('PLUGIN_SOLOIST_KEY_EXPIRED'), $key->{expires}), type => 'text' };
    }

    push @items, {
        name => string($state->{running} ? 'PLUGIN_SOLOIST_APP_RESTART' : 'PLUGIN_SOLOIST_APP_START'),
        type => 'link',
        url  => \&_appServiceAction,
        passthrough => [ $state->{running} ? 'restart' : 'start' ],
        nextWindow  => 'refresh',
    };

    # Plain playable item: the one to save as a favourite.
    push @items, {
        name  => string('PLUGIN_SOLOIST_SOURCE_ITEM'),
        line2 => string('PLUGIN_SOLOIST_APP_FAVOURITE_HINT'),
        url   => SOURCE_URL,
        type  => 'audio',
    };
    return \@items;
}

sub _spotifyStatusText {
    my ($state) = @_;
    require Plugins::Soloist::Metadata;
    return string('PLUGIN_SOLOIST_APP_NOT_CONNECTED')
        unless $state->{running} && Plugins::Soloist::Metadata->isConnected();
    return string('PLUGIN_SOLOIST_APP_SESSION_ELSEWHERE') if defined $deviceActive && !$deviceActive;
    my $meta = $lastSoloistMetadata;
    if (ref $meta eq 'HASH' && length($meta->{title} || '')) {
        my $track = $meta->{artist} ? "$meta->{artist} - $meta->{title}" : $meta->{title};
        return sprintf(string($spotifyPlaying ? 'PLUGIN_SOLOIST_APP_SPOTIFY_PLAYING'
            : 'PLUGIN_SOLOIST_APP_SPOTIFY_PAUSED'), $track);
    }
    return sprintf(string('PLUGIN_SOLOIST_APP_WAITING'), $prefs->get('deviceName') || 'Soloist Connect');
}

# Switch $client to the Soloist source when the app is opened. Returns
# 'started', 'on-source', 'busy' or ''.
sub _appAutoStart {
    my ($client) = @_;
    return 'on-source' if _isSoloistSource($client);
    if (eval { $client->isPlaying() }) {
        $log->info('Soloist app opened, but ' . $client->name . ' is playing another source; not switching');
        return 'busy';
    }
    # UIs re-request the menu (back/refresh); don't act twice in a row.
    my $now = Time::HiRes::time();
    return '' if $appStartedAt{$client->id} && $now - $appStartedAt{$client->id} < 10;
    $appStartedAt{$client->id} = $now;
    $log->info('Soloist app opened: starting ' . SOURCE_URL . ' on ' . $client->name);
    _startSourceOn($client);
    return 'started';
}

sub _startSourceOn {
    my ($client) = @_;
    require Plugins::Soloist::Manager;
    my $state = Plugins::Soloist::Manager->status();
    Plugins::Soloist::Manager->start() unless $state->{running} || $state->{starting};
    $suppressTransportUntil{$client->id} = Time::HiRes::time() + 3;
    $client->execute(['playlist', 'play', SOURCE_URL, string('PLUGIN_SOLOIST_SOURCE_ITEM')]);
    # Resume Spotify too, but only when this device certainly holds the
    # session: a play command is account-wide and would otherwise start
    # the phone.
    if ($deviceActive && defined $spotifyPlaying && !$spotifyPlaying) {
        require Plugins::Soloist::Control;
        Plugins::Soloist::Control->send('play');
    }
}

sub _appPlay {
    my ($client, $callback, $args) = @_;
    $client = _masterClient($client);
    unless ($client) {
        $callback->({ items => [{ name => string('PLUGIN_SOLOIST_APP_NO_PLAYER'), type => 'text' }] });
        return;
    }
    if (_isSoloistSource($client)) {
        $client->execute(['play']) unless eval { $client->isPlaying() };
    }
    else {
        $appStartedAt{$client->id} = Time::HiRes::time();
        _startSourceOn($client);
    }
    $callback->({ items => [{ name => sprintf(string('PLUGIN_SOLOIST_APP_PLAYING_ON'), $client->name), type => 'text' }] });
}

sub _appServiceAction {
    my ($client, $callback, $args, $action) = @_;
    require Plugins::Soloist::Manager;
    my $ok = $action eq 'restart' ? Plugins::Soloist::Manager->restart() : Plugins::Soloist::Manager->start();
    my $text = $ok
        ? string($action eq 'restart' ? 'PLUGIN_SOLOIST_MSG_RESTARTING' : 'PLUGIN_SOLOIST_MSG_STARTING')
        : (Plugins::Soloist::Manager->lastError() || 'Failed');
    $callback->({ items => [{ name => $text, type => 'text' }] });
}

# Called by ProtocolHandler::getMetadataFor for soloist: URLs.
sub sourceMetadata {
    my ($class, $client, $url) = @_;
    return unless $client && defined $url && $url =~ /^soloist:/i;
    my $master = _masterClient($client);
    my $meta = $master ? $master->pluginData('soloistMetadata') : undef;
    return unless ref($meta) eq 'HASH' && ($meta->{url} || '') eq $url;
    return unless _isActiveSource($master);
    # LMS's cache is an SQLite file on the SD card. This function runs on every
    # status poll (about once a second per UI); writing each time stalled LMS
    # for seconds when the card was busy. Only write when the cover changed.
    _cacheCover($url, $meta->{cover});
    return $meta;
}

sub _cacheCover {
    my ($url, $cover) = @_;
    return unless $cover && defined $url;
    return if ($coverCachedFor{$url} || '') eq $cover;
    $coverCachedFor{$url} = $cover;
    $metadataCache->set("remote_image_$url", $cover, 3600);
}

# ---------------------------------------------------------------------------
# Next/Previous interception

sub _installJumpIntercept {
    return if $jumpInterceptInstalled;
    my $fallback = eval { require Slim::Control::Commands; Slim::Control::Commands->can('playlistJumpCommand') };
    my @params = ('_index', '_fadein', '_noplay', '_seekdata');

    my $prevJump = Slim::Control::Request::addDispatch(
        ['playlist', 'jump', @params], [1, 0, 0, \&_playlistJumpCommand]);
    my $prevIndex = Slim::Control::Request::addDispatch(
        ['playlist', 'index', @params], [1, 0, 0, \&_playlistJumpCommand]);

    $originalJumpCommand  = ref($prevJump)  eq 'CODE' ? $prevJump  : $fallback;
    $originalIndexCommand = ref($prevIndex) eq 'CODE' ? $prevIndex : $fallback;
    $jumpInterceptInstalled = 1;

    if ($originalJumpCommand && $originalIndexCommand) {
        $log->info('Installed LMS Next/Previous intercept for the Soloist source ('
            . (ref($prevJump) eq 'CODE' ? 'chained' : 'fallback') . ')');
    }
    else {
        $log->error('Could not find the original LMS playlist jump command; '
            . 'Next/Previous on non-Spotify sources may not work. Please report your LMS version.');
    }
}

sub _removeJumpIntercept {
    return unless $jumpInterceptInstalled;
    my @params = ('_index', '_fadein', '_noplay', '_seekdata');
    Slim::Control::Request::addDispatch(['playlist', 'jump', @params], [1, 0, 0, $originalJumpCommand])
        if $originalJumpCommand;
    Slim::Control::Request::addDispatch(['playlist', 'index', @params], [1, 0, 0, $originalIndexCommand])
        if $originalIndexCommand;
    $jumpInterceptInstalled = 0;
}

sub _playlistJumpCommand {
    my ($request) = @_;
    Plugins::Soloist::Watchdog->mark('LMS playlist jump');
    my $original = $request->isCommand([['playlist'], ['index']])
        ? $originalIndexCommand : $originalJumpCommand;

    my $master = _masterClient($request->client());
    my $index = $request->getParam('_index');

    # Only relative jumps (+1, -1, +0) while the player is on our soloist: item
    # are redirected. Absolute indexes (e.g. starting the favourite) pass on.
    if ($master && defined $index && $index =~ /\A[+-]\d+\z/ && _isSoloistSource($master)
        && _sessionIsHere()) {
        my ($action, $extra) = $index eq '+0' ? ('seek', { position_ms => 0 })
            : $index =~ /\A\+/ ? ('skip_next') : ('skip_prev');
        require Plugins::Soloist::Control;
        if (Plugins::Soloist::Control->send($action, $extra)) {
            _flushIfDelayed($master, "LMS $action", 2);
            $log->info("LMS $index forwarded to Soloist as $action (LMS stream kept open)");
            $request->setStatusDone();
            return;
        }
        $log->warn("Soloist did not accept $action ("
            . Plugins::Soloist::Control->lastError() . '); letting LMS handle the jump');
    }

    return $original->($request) if $original;
    $request->setStatusBadDispatch();
}

# ---------------------------------------------------------------------------
# Player helpers

sub _masterClient {
    my ($client) = @_;
    return unless $client;
    return $client->master if $client->can('master') && $client->master;
    return $client;
}

sub _isSoloistSource {
    my ($client) = @_;
    $client = _masterClient($client);
    return 0 unless $client;
    my $song = eval { $client->playingSong() } || eval { Slim::Player::Playlist::song($client) };
    return 0 unless $song;
    # playingSong() returns a Slim::Player::Song; Playlist::song() a track.
    my @urls = map { my $m = $_; scalar eval { $song->$m() } } qw(path streamUrl url);
    my $track = eval { $song->track };
    push @urls, scalar eval { $track->url } if ref $track;
    for my $url (@urls) {
        return 1 if defined $url && $url =~ /^soloist:/i;
    }
    return 0;
}

sub _isActiveSource {
    my ($client) = @_;
    $client = _masterClient($client);
    return 0 unless $client;
    return 1 if _isSoloistSource($client);
    return $activeSourcePlayer && $activeSourcePlayer eq $client->id ? 1 : 0;
}

sub _onNewSong {
    my ($request) = @_;
    Plugins::Soloist::Watchdog->mark('LMS newsong');
    my $client = _masterClient($request->client());
    return unless $client;
    if (_isSoloistSource($client)) {
        $activeSourcePlayer = $client->id;
        $activeSourceClient = $client;
        $sourceStartedAt{$client->id} = Time::HiRes::time();
        # The stream (re)opened: LMS resets the title to the item name, so
        # force our metadata to be re-applied.
        delete $lastAppliedMetadataKey{$client->id};
        $log->info('Soloist source is active on LMS player ' . $client->id);
        _applySoloistMetadata($client, $lastSoloistMetadata) if $lastSoloistMetadata;
    }
    elsif ($activeSourcePlayer && $activeSourcePlayer eq $client->id) {
        $activeSourcePlayer = undef;
        $activeSourceClient = undef;
        delete $lastAppliedMetadataKey{$client->id};
        $log->info('LMS player left the Soloist source');
    }
}

# ---------------------------------------------------------------------------
# Soloist -> LMS

sub soloistConnectionChanged {
    my ($class, $connected) = @_;
    # A reconnect (e.g. after Soloist restart) must count as a fresh start so
    # an already-playing Spotify session can resume the LMS stream.
    $spotifyPlaying = undef;
    $deviceActive = undef;
}

# Spotify commands are account-wide: a pause sent while the Connect session
# is on a phone pauses the phone. Only forward while this device holds it
# (or while Soloist hasn't told us yet).
sub _sessionIsHere {
    return !defined($deviceActive) || $deviceActive ? 1 : 0;
}

sub _boolField {
    my ($value) = @_;
    return undef unless defined $value;
    return $value ? 1 : 0 if JSON::XS::is_bool($value);
    return $value ? 1 : 0 if !ref($value) && $value =~ /\A[01]\z/;
    return undef;
}

sub _updateSpotifyStatus {
    my ($status) = @_;
    return unless defined $status && !ref $status;
    # Soloist reports "buffering" between tracks and before the first audio;
    # it says nothing about whether the user wants playback, so hold state.
    return if $status eq 'buffering';
    my $nowPlaying = $status eq 'playing' ? 1 : 0;
    my $wasPlaying = $spotifyPlaying;
    $spotifyPlaying = $nowPlaying;
    _scheduleResume() if $nowPlaying && !$wasPlaying;
}

sub _scheduleResume {
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_resumeLmsForSpotify);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + 0.5, \&_resumeLmsForSpotify);
}

# Called by the persistent local Soloist WebSocket listener.
sub handleSoloistEvent {
    my ($class, $event) = @_;
    return unless ref($event) eq 'HASH';
    my $type = $event->{type} || '';
    Plugins::Soloist::Watchdog->mark("Soloist event $type");
    $spotifyVolume = $event->{volume}
        if defined $event->{volume} && !ref $event->{volume} && $event->{volume} =~ /\A\d+(?:\.\d+)?\z/;
    _logSoloistError($event) if $type eq 'error';

    # Many events omit is_active; only trust it when present.
    my $active = _boolField($event->{is_active});
    if (defined $active) {
        my $was = $deviceActive;
        $deviceActive = $active;
        if ($active && !(defined $was && $was) && $spotifyPlaying) {
            _scheduleResume();     # session handed to us while already playing
        }
        if (!$active && (!defined $was || $was)) {
            $log->info('Spotify Connect session is now on another device');
        }
    }

    if ($type eq 'playback_state' || $type eq 'playback_changed') {
        _updateSpotifyStatus($event->{status});
    }
    return unless $type eq 'playback_state' || $type eq 'track_changed';

    my $item = $event->{item};
    return unless ref($item) eq 'HASH';
    my $decorations = ref($item->{decorations}) eq 'HASH' ? $item->{decorations} : {};
    my $identity = ref($decorations->{identity}) eq 'HASH' ? $decorations->{identity} : {};
    my $parent = ref($decorations->{parent}) eq 'HASH' ? $decorations->{parent}->{entity} : undef;
    my $parentDecorations = ref($parent) eq 'HASH' && ref($parent->{decorations}) eq 'HASH'
        ? $parent->{decorations} : {};
    my $albumIdentity = ref($parentDecorations->{identity}) eq 'HASH'
        ? $parentDecorations->{identity} : {};
    my $creators = ref($decorations->{creators}) eq 'ARRAY' ? $decorations->{creators} : [];
    my @artists;
    for my $creator (@{$creators}) {
        next unless ref($creator) eq 'HASH' && ref($creator->{entity}) eq 'HASH';
        my $artistDecorations = $creator->{entity}->{decorations};
        next unless ref($artistDecorations) eq 'HASH' && ref($artistDecorations->{identity}) eq 'HASH';
        my $name = $artistDecorations->{identity}->{name};
        push @artists, $name if defined $name && length $name;
    }
    my $title = $identity->{name} || '';
    my $artist = join(', ', @artists);

    my $playback = ref($decorations->{playback}) eq 'HASH' ? $decorations->{playback} : {};
    my $duration = ($playback->{duration_ms} || 0) / 1000;
    my $album = $albumIdentity->{name} || '';
    my $cover = '';
    my $visual = ref($decorations->{visual_identity}) eq 'HASH' ? $decorations->{visual_identity} : {};
    my $covers = ref($visual->{cover}) eq 'ARRAY' ? $visual->{cover} : [];
    # ~300 px is plenty for LMS UIs; larger sizes only grow LMS's image cache.
    for my $size (qw(default large small xlarge)) {
        my ($match) = grep { ref($_) eq 'HASH' && ($_->{size} || '') eq $size && $_->{url} } @{$covers};
        if ($match) { $cover = $match->{url}; last; }
    }
    $cover ||= $covers->[0]->{url} if @{$covers} && ref($covers->[0]) eq 'HASH';

    my $meta = {
        title    => $title,
        artist   => $artist,
        album    => $album,
        duration => $duration,
        cover    => $cover,
        uri      => $item->{uri} || '',
        position => _soloistPositionSeconds($event),
        playing  => ($event->{status} || '') eq 'playing' ? 1 : 0,
    };
    # Soloist can emit a compact track_changed event for the same URI before a
    # fuller playback_state. Keep rich fields instead of blanking them.
    if (ref($lastSoloistMetadata) eq 'HASH'
        && $meta->{uri} && $meta->{uri} eq ($lastSoloistMetadata->{uri} || '')) {
        for my $field (qw(title artist album duration cover)) {
            $meta->{$field} = $lastSoloistMetadata->{$field}
                if (!defined $meta->{$field} || $meta->{$field} eq '' || $meta->{$field} eq '0')
                    && defined $lastSoloistMetadata->{$field}
                    && $lastSoloistMetadata->{$field} ne '';
        }
        $meta->{position} = $lastSoloistMetadata->{position}
            if !defined $meta->{position} && defined $lastSoloistMetadata->{position};
    }
    return unless length($meta->{title}) || length($meta->{artist});
    my $previous = $lastSoloistMetadata;
    my $previousAt = $lastTrackPositionAt;
    my $finished;    # [metadata, start, end] of the track that just ended
    if (!ref($previous) || ($meta->{uri} || '') ne ($previous->{uri} || '')) {
        my $now = Time::HiRes::time();
        $finished = [$previous, $trackStartedAt, $now] if ref($previous);
        $trackStartedAt = $now;
    }
    $lastSoloistMetadata = $meta;
    # Diagnostics only: never let the measurement line stop the metadata.
    if ($finished) {
        eval { _logMeasurement(@$finished); 1 }
            or $log->warn("Could not log the measurement: $@");
    }
    $lastTrackPositionAt = Time::HiRes::time() if defined $meta->{position};

    if (main::DEBUGLOG && $log->is_debug) {
        my $signature = join("\x1f", $meta->{uri}, $meta->{title}, $meta->{artist},
            $meta->{album}, int($meta->{duration}), $meta->{cover} ? 1 : 0);
        if ($signature ne $lastMetadataDiagnosticSignature) {
            $lastMetadataDiagnosticSignature = $signature;
            $log->debug("Soloist metadata received: type=$type title=$meta->{title}"
                . " artist=$meta->{artist} album=$meta->{album} duration=" . int($meta->{duration})
                . ' cover=' . ($meta->{cover} ? 'yes' : 'no'));
        }
    }

    my $client = _masterClient($activeSourceClient);
    return unless $client && _isActiveSource($client);

    # A new track in Spotify. If the player is lagging behind, this is the
    # moment to drop the backlog: right away for a skip (the rest of the old
    # track isn't wanted), at a natural track end only when the delay is big.
    if (ref($previous) eq 'HASH' && $previous->{uri} && $meta->{uri}
        && $meta->{uri} ne $previous->{uri}) {
        my $at = $previous->{position};
        $at += Time::HiRes::time() - $previousAt if defined $at && $previous->{playing} && $previousAt;
        my $natural = defined $at && $previous->{duration} && $at >= $previous->{duration} - 4;
        _flushIfDelayed($client, $natural ? 'track change' : 'Spotify skip', $natural ? 10 : 2);
    }
    _applySoloistMetadata($client, $meta);
}

# ---------------------------------------------------------------------------
# Delay between Spotify and the player
#
# The source is live: audio arrives in real time and can never be played
# faster. Whatever piles up (after an LMS stall, a pause, clock drift) stays
# as extra delay, so Next or Pause seem to react seconds late. The delay is
# measured as time since the capture started minus what the player has
# played of this stream. Restarting the stream drops the backlog.

# "Spotify LOSSLESS 16-bit", "Spotify LOSSLESS 24-bit", "Spotify 16-bit
# (gain -2.0 dB)", "Spotify NOT BIT-PERFECT", or plain "Spotify" while the
# measurement isn't sure yet. See Plugins::Soloist::Measure.
sub sourceLabel {
    return 'Spotify' unless $prefs->get('measureSource');
    require Plugins::Soloist::Measure;
    my $part = Plugins::Soloist::Measure::labelPart(
        Plugins::Soloist::Measure->verdict($trackStartedAt)) or return 'Spotify';
    $part .= sprintf(' (volume %d%%)', $spotifyVolume)
        if $part !~ /LOSSLESS/ && defined $spotifyVolume && $spotifyVolume < 100;
    return "Spotify $part";
}

# One line per track in soloist.log with what the measurement saw, so a
# verdict can be checked afterwards.
sub _logMeasurement {
    my ($meta, $since, $until) = @_;
    return unless $prefs->get('measureSource') && $since && $until - $since > 5;
    require Plugins::Soloist::Measure;
    my $summary = Plugins::Soloist::Measure->summary($since, $until) or return;
    my $title = join(' - ', grep { defined($_) && length($_) } $meta->{artist}, $meta->{title});
    $title =~ s/[\x00-\x1f]+/ /g;
    require Plugins::Soloist::LogWriter;
    Plugins::Soloist::LogWriter->write(sprintf("--- measure %s: \"%s\" (%.0f s): %s\n",
        scalar localtime($until), $title, $until - $since, $summary));
}

sub captureStarted {
    my ($class, $client) = @_;
    $client = _masterClient($client) or return;
    $captureStartedAt{$client->id} = Time::HiRes::time();
}

sub delaySeconds {
    my ($class, $client) = @_;
    my $d = $class->delayDetails($client) or return;
    return $d->{delay};
}

# The delay two ways, and the larger one counts:
#   elapsed  time since the capture started minus what the player has played
#   buffers  what squeezelite reports is waiting in its stream buffer (FLAC)
#            and output buffer (decoded audio); this sees a backlog even when
#            the elapsed time can't (e.g. the player clock drifting against
#            the Loopback until its buffers are full, ~18 s)
sub delayDetails {
    my ($class, $client) = @_;
    $client = _masterClient($client) or return;
    return unless _isSoloistSource($client) && eval { $client->isPlaying() };
    my $start = $captureStartedAt{$client->id} or return;
    my $now = Time::HiRes::time();
    my %d;

    my $played = eval { $client->songElapsedSeconds() };
    if (defined $played && $played > 0) {
        my $delay = $now - $start - $played;
        $d{elapsed} = $delay < 0 ? 0 : $delay;
    }

    # squeezelite: output buffer in 8-byte frames (32-bit stereo) at the
    # stream rate; stream buffer in FLAC bytes, which arrive in real time.
    my $out = eval { $client->outputBufferFullness() };
    my $in  = eval { $client->bufferFullness() };
    my $received = eval { $client->bytesReceived() } || 0;
    my $since = $now - $start;
    if (defined $out && defined $in && $since > 5 && $received > 0) {
        my $inRate = $received / $since;
        $d{buffers}  = $out / (44100 * 8) + ($inRate > 0 ? $in / $inRate : 0);
        $d{streamKB} = int($in / 1024);
        $d{outputKB} = int($out / 1024);
    }

    my @known = grep { defined } @d{qw(elapsed buffers)};
    return unless @known;
    ($d{delay}) = sort { $b <=> $a } @known;
    return \%d;
}

sub _flushIfDelayed {
    my ($client, $reason, $threshold) = @_;
    return unless $prefs->get('keepDelayLow');
    my $d = __PACKAGE__->delayDetails($client);
    $log->info(sprintf('Delay check (%s): %s', $reason, _delayText($d)));
    return unless $d && $d->{delay} > $threshold;
    _flushStream($client, sprintf('%s, delay %.1f s', $reason, $d->{delay}));
}

sub _delayText {
    my ($d) = @_;
    return 'unknown' unless $d;
    return join(', ', (defined $d->{elapsed} ? sprintf('by elapsed time %.1f s', $d->{elapsed}) : 'elapsed time n/a'),
        (defined $d->{buffers} ? sprintf('in player buffers %.1f s (stream %d KB, output %d KB)',
            $d->{buffers}, $d->{streamKB}, $d->{outputKB}) : 'player buffers n/a'));
}

sub _flushStream {
    my ($client, $reason) = @_;
    $client = _masterClient($client) or return;
    my $now = Time::HiRes::time();
    return if $lastFlushAt{$client->id} && $now - $lastFlushAt{$client->id} < 5;
    $lastFlushAt{$client->id} = $now;
    $log->info("Restarting the Soloist stream on " . $client->name . " to drop the backlog ($reason)");
    Plugins::Soloist::Watchdog->mark("stream restart ($reason)");
    require Plugins::Soloist::LogWriter;
    Plugins::Soloist::LogWriter->write('--- stream restart ' . localtime() . " on " . $client->name . ": $reason\n");
    $suppressTransportUntil{$client->id} = $now + 4;
    $sourceStartedAt{$client->id} = $now;
    delete $captureStartedAt{$client->id};
    $client->execute(['playlist', 'play', SOURCE_URL, string('PLUGIN_SOLOIST_SOURCE_ITEM')]);
}

# Soloist error events were invisible so far. Log their content, each
# distinct message at most once a minute.
sub _logSoloistError {
    my ($event) = @_;
    my $text = eval { JSON::XS->new->canonical->encode($event) } || 'unreadable error event';
    $text = substr($text, 0, 400) . '...' if length $text > 400;
    my $now = time();
    return if ($lastErrorLogged{$text} || 0) > $now - 60;
    %lastErrorLogged = () if keys %lastErrorLogged > 50;
    $lastErrorLogged{$text} = $now;
    $log->warn("Soloist reported an error: $text");
    require Plugins::Soloist::LogWriter;
    Plugins::Soloist::LogWriter->write('--- soloist error ' . localtime() . ": $text\n");
}

# When Spotify starts playing on this Connect device, make sure the LMS player
# is actually streaming the Soloist source. Never interrupts another source
# that is currently playing.
sub _resumeLmsForSpotify {
    Plugins::Soloist::Watchdog->mark('auto-resume check');
    return unless $spotifyPlaying && _sessionIsHere();
    my $client;
    if (my $id = $prefs->get('autoPlayPlayer')) {
        $client = Slim::Player::Client::getClient($id);
        $log->warn("Auto-play player $id is not connected to LMS") unless $client;
    }
    $client ||= $activeSourceClient;
    $client = _masterClient($client);
    return unless $client;

    my $isPlaying = eval { $client->isPlaying() } ? 1 : 0;
    my $onSource = _isSoloistSource($client);
    return if $isPlaying && $onSource;
    if ($isPlaying) {
        $log->info('Spotify started, but LMS player ' . $client->name . ' is playing another source; leaving it alone');
        return;
    }

    $suppressTransportUntil{$client->id} = Time::HiRes::time() + 3;
    if ($onSource) {
        $log->info('Spotify started; resuming the Soloist source on ' . $client->name);
        $client->execute(['play']);
        return;
    }
    return unless $prefs->get('autoPlayPlayer');   # only switch sources when configured
    $log->info('Spotify started; starting ' . SOURCE_URL . ' on ' . $client->name);
    $client->execute(['playlist', 'play', SOURCE_URL, string('PLUGIN_SOLOIST_SOURCE_ITEM')]);
}

sub _soloistPositionSeconds {
    my ($event) = @_;
    my $position = $event->{position};
    return undef unless defined $position;
    my ($milliseconds, $timestamp);
    if (ref($position) eq 'HASH') {
        $milliseconds = defined $position->{position_ms} ? $position->{position_ms} : $position->{position};
        $timestamp = $position->{timestamp_ms};
    }
    elsif (!ref($position) && $position =~ /^\d+(?:\.\d+)?$/) {
        $milliseconds = $position;
    }
    return undef unless defined $milliseconds && $milliseconds =~ /^\d+(?:\.\d+)?$/;
    my $nowMs = Time::HiRes::time() * 1000;
    $timestamp = $nowMs unless defined $timestamp && $timestamp =~ /^\d+(?:\.\d+)?$/;
    $timestamp = $nowMs if abs($nowMs - $timestamp) > 2000;
    my $speed = ($event->{status} || '') eq 'playing' ? 1 : 0;
    return ($milliseconds + (($nowMs - $timestamp) * $speed)) / 1000;
}

sub _applySoloistMetadata {
    my ($client, $meta) = @_;
    return unless $client && ref($meta) eq 'HASH';
    my ($title, $artist, $album, $duration, $cover) = @{$meta}{qw(title artist album duration cover)};
    return unless length($title || '') || length($artist || '');
    # Remote streams can expose a distinct streamingSong object from the
    # playlist's playingSong. Update the object LMS is actually rendering.
    my $song = eval { $client->streamingSong() }
        || eval { $client->playingSong() };
    return unless $song && ref($song) && eval { $song->can('streamUrl') };
    my $track = eval { $song->track };
    my $logicalUrl = $track ? eval { $track->url } : undef;
    my $streamUrl = eval { $song->streamUrl };
    $logicalUrl ||= $streamUrl;
    my $display = $artist ? "$artist - $title" : $title;

    if (defined $meta->{position} && $song->can('startOffset')) {
        my $elapsed = eval { $client->controller()->playingSongElapsed() };
        $elapsed = 0 unless defined $elapsed && $elapsed >= 0;
        my $offset = eval { $song->startOffset() } || 0;
        my $drift = $meta->{position} - $elapsed;
        $song->startOffset($offset + $drift) if abs($drift) > 1.5;
    }

    my $metadataKey = join("\x1f", map { defined $_ ? $_ : '' }
        @{$meta}{qw(uri title artist album duration cover)});
    return if ($lastAppliedMetadataKey{$client->id} || '') eq $metadataKey;
    $lastAppliedMetadataKey{$client->id} = $metadataKey;
    Plugins::Soloist::Watchdog->mark('apply track metadata to LMS');

    $client->pluginData(soloistMetadata => {
        %{$meta}, displayTitle => $display, url => $logicalUrl || '',
    });
    _cacheCover($_, $cover) for grep { defined $_ && length $_ } ($logicalUrl, $streamUrl);
    eval {
        require Slim::Music::Info;
        # LMS caches the menu/favourite name as the URL title, so replace
        # the cached URL title as well as the runtime title.
        for my $url (grep { defined $_ && length $_ } ($logicalUrl,
                ($streamUrl && $streamUrl ne ($logicalUrl || '')) ? $streamUrl : ())) {
            Slim::Music::Info::setTitle($url, $display);
            Slim::Music::Info::setCurrentTitle($url, $display, $client);
        }
        $song->duration($duration) if $duration && $song->can('duration');
        $client->streamingProgressBar({ url => $streamUrl, duration => $duration })
            if $duration && $streamUrl && $client->can('streamingProgressBar');
        $song->pluginData(info => {
            title    => $title,
            artist   => $artist,
            album    => $album,
            duration => $duration,
            cover    => $cover,
            icon     => $cover,
            url      => $logicalUrl || '',
        });
        $client->currentPlaylistUpdateTime(Time::HiRes::time())
            if $client->can('currentPlaylistUpdateTime');
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        1;
    } or $log->warn('Could not update LMS with Soloist track metadata: ' . $@);
    $log->info("Soloist metadata applied: $display");
}

# ---------------------------------------------------------------------------
# LMS -> Soloist transport

sub _sendTransport {
    my ($client, $command) = @_;
    $client = _masterClient($client);
    return unless _isActiveSource($client);
    my $now = Time::HiRes::time();
    # Our own auto-resume issues LMS play commands; don't echo them back.
    return 1 if ($suppressTransportUntil{$client->id} || 0) > $now;
    # While LMS was paused the capture kept running; that audio would now
    # play first. Resume with a fresh stream instead.
    if ($command eq 'pause') {
        $pausedAt{$client->id} = $now;
    }
    elsif ($command eq 'play' && $pausedAt{$client->id}) {
        my $paused = $now - delete $pausedAt{$client->id};
        _flushStream($client, sprintf('resume after %.0f s pause', $paused))
            if $paused > 2 && $prefs->get('keepDelayLow');
    }
    unless (_sessionIsHere()) {
        $log->info("Not forwarding $command: the Spotify session is on another device");
        return 0;
    }
    my $key = $client->id . ':' . $command;
    return 1 if $lastTransportAt{$key} && $now - $lastTransportAt{$key} < 0.25;
    $lastTransportAt{$key} = $now;
    $log->info("LMS->Soloist transport: $command (player=" . $client->id . ')');
    Plugins::Soloist::Watchdog->mark("LMS->Soloist $command");
    require Plugins::Soloist::Control;
    Plugins::Soloist::Control->send($command);
}

sub _onPlaylistPause {
    my ($request) = @_;
    my $client = _masterClient($request->client());
    return unless _isActiveSource($client);
    if ($request->isCommand([['playlist'], ['pause']])) {
        # Opening the soloist: stream can emit a transient pause while LMS replaces
        # the previous playlist item. Don't echo that back to Spotify.
        if ($sourceStartedAt{$client->id}
            && Time::HiRes::time() - $sourceStartedAt{$client->id} < 3) {
            $log->debug('Ignoring transient LMS pause while the Soloist source starts');
            return;
        }
        # LMS convention: _newvalue 1 = paused, 0/undef = resumed.
        my $newvalue = $request->getParam('_newvalue');
        _sendTransport($client, (defined $newvalue && $newvalue ne '0') ? 'pause' : 'play');
    }
    else {
        # LMS emits playlist stop internally while opening/replacing a stream;
        # treating it as a Spotify pause made Play immediately pause again.
        $log->debug('Ignoring LMS playlist stop; it may be an internal stream transition');
    }
}

sub _onPlayCommand {
    my ($request) = @_;
    _sendTransport($request->client(), 'play');
}

sub _onSimplePauseCommand {
    my ($request) = @_;
    my $client = _masterClient($request->client());
    return unless _isActiveSource($client);
    my $value = $request->getParam('_newvalue');
    my $pause;
    if (defined $value) {
        $pause = $value ne '0' ? 1 : 0;
    }
    else {
        # Toggle: subscribers run after the command, so read the new state.
        $pause = eval { $client->isPlaying() } ? 0 : 1;
    }
    _sendTransport($client, $pause ? 'pause' : 'play');
}

sub _onModeCommand {
    my ($request) = @_;
    my $client = _masterClient($request->client());
    return unless _isActiveSource($client);
    my $mode = eval { $request->getRequest(1) } || '';
    return unless $mode eq 'play' || $mode eq 'pause';
    _sendTransport($client, $mode);
}

1;
