package Plugins::Soloist::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

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
my $activeWaveInputPlayer;
my $activeWaveInputClient;
my $waveInputOriginalMetadata;
my $waveInputMetadataHookInstalled;
my $originalJumpCommand;
my $originalIndexCommand;
my $jumpInterceptInstalled;
my $lastSoloistMetadata;
my $lastMetadataDiagnosticSignature = '';
my $spotifyPlaying;            # undef = unknown (not yet seen since connect)
my $deviceActive;              # Soloist is_active: undef = unknown
my %lastAppliedMetadataKey;    # per LMS player id
my %waveInputStartedAt;
my %lastTransportAt;
my %suppressTransportUntil;
my $autoStartAttempts = 0;

use constant DEFAULT_WAVIN_URL => 'wavin:plughw:CARD=Loopback,DEV=1,SUBDEV=0';

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
        cacheDir        => '/mnt/mmcblk0p2/tce/soloist-prototype/cache',
        wsAddress       => '127.0.0.1:9878',
        maxTlengthMs    => 500,
        initialVolume   => 100,
        cacheSize       => 100,
        autoPlayPlayer  => '',
        wavinUrl        => DEFAULT_WAVIN_URL,
        shimDiagnostics => 0,
    });

    $class->SUPER::initPlugin(@_);

    require Plugins::Soloist::Settings;
    Plugins::Soloist::Settings->new();

    # WaveInput supplies its own protocol getMetadataFor(), so LMS never
    # reaches the generic RemoteMetadata provider for wavin: URLs. Wrap that
    # method and enrich its response only while our WaveInput source is active.
    _installWaveInputMetadataHook();

    # LMS Next/Previous must not run LMS's own playlist jump on the single
    # wavin: item: that closes the arecord capture and leaves the player
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
    _removeJumpIntercept();
    require Plugins::Soloist::Manager;
    Plugins::Soloist::Manager->stop();
    require Plugins::Soloist::Metadata;
    Plugins::Soloist::Metadata->stop();
    _removeWaveInputMetadataHook();
    $activeWaveInputPlayer = undef;
    $activeWaveInputClient = undef;
    $lastSoloistMetadata = undef;
    $lastMetadataDiagnosticSignature = '';
    $spotifyPlaying = undef;
    %lastAppliedMetadataKey = ();
    %waveInputStartedAt = ();
    %lastTransportAt = ();
    %suppressTransportUntil = ();
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
# WaveInput metadata hook

sub _installWaveInputMetadataHook {
    my $loaded = eval { require Plugins::WaveInput::WAVIN; 1 };
    unless ($loaded) {
        $log->warn('Could not load WaveInput metadata handler: ' . ($@ || 'unknown error'));
        return;
    }

    no strict 'refs';
    no warnings 'redefine';
    my $slot = 'Plugins::WaveInput::WAVIN::getMetadataFor';
    my $original = *{$slot}{CODE};
    unless ($original) {
        $log->warn('WaveInput getMetadataFor method was not found; Soloist artwork bridge is inactive');
        return;
    }
    return if $waveInputMetadataHookInstalled;

    $waveInputOriginalMetadata = $original;
    *{$slot} = sub {
        my ($class, $client, $url, @rest) = @_;
        my $base = $original->(@_);
        return $base unless $client && defined $url && $url =~ /^wavin:/i;

        my $master = _masterClient($client);
        my $meta = $master ? $master->pluginData('soloistMetadata') : undef;
        return $base unless ref($meta) eq 'HASH' && ($meta->{url} || '') eq $url;
        return $base unless _isActiveWaveInput($master);

        my %result = ref($base) eq 'HASH' ? %{$base} : ();
        @result{qw(title artist album duration)} = @{$meta}{qw(title artist album duration)};
        if ($meta->{cover}) {
            $result{cover} = $meta->{cover};
            $result{icon} = $meta->{cover};
            $metadataCache->set("remote_image_$url", $meta->{cover}, 3600);
        }
        $result{type} = 'Spotify';
        return \%result;
    };
    $waveInputMetadataHookInstalled = 1;
    $log->info('Wrapped WaveInput getMetadataFor for live metadata and artwork');
}

sub _removeWaveInputMetadataHook {
    return unless $waveInputMetadataHookInstalled && $waveInputOriginalMetadata;
    no strict 'refs';
    no warnings 'redefine';
    *{'Plugins::WaveInput::WAVIN::getMetadataFor'} = $waveInputOriginalMetadata;
    $waveInputOriginalMetadata = undef;
    $waveInputMetadataHookInstalled = 0;
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
        $log->info('Installed LMS Next/Previous intercept for WaveInput playback ('
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
    my $original = $request->isCommand([['playlist'], ['index']])
        ? $originalIndexCommand : $originalJumpCommand;

    my $master = _masterClient($request->client());
    my $index = $request->getParam('_index');

    # Only relative jumps (+1, -1, +0) while the player is on our wavin: item
    # are redirected. Absolute indexes (e.g. starting the favourite) pass on.
    if ($master && defined $index && $index =~ /\A[+-]\d+\z/ && _isWaveInput($master)
        && _sessionIsHere()) {
        my ($action, $extra) = $index eq '+0' ? ('seek', { position_ms => 0 })
            : $index =~ /\A\+/ ? ('skip_next') : ('skip_prev');
        require Plugins::Soloist::Control;
        if (Plugins::Soloist::Control->send($action, $extra)) {
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

sub _isWaveInput {
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
        return 1 if defined $url && $url =~ /^wavin:/i;
    }
    return 0;
}

sub _isActiveWaveInput {
    my ($client) = @_;
    $client = _masterClient($client);
    return 0 unless $client;
    return 1 if _isWaveInput($client);
    return $activeWaveInputPlayer && $activeWaveInputPlayer eq $client->id ? 1 : 0;
}

sub _onNewSong {
    my ($request) = @_;
    my $client = _masterClient($request->client());
    return unless $client;
    if (_isWaveInput($client)) {
        $activeWaveInputPlayer = $client->id;
        $activeWaveInputClient = $client;
        $waveInputStartedAt{$client->id} = Time::HiRes::time();
        # WaveInput resets the title to its station name whenever the stream
        # (re)opens, so force our metadata to be re-applied.
        delete $lastAppliedMetadataKey{$client->id};
        $log->info('WaveInput playback is active for LMS player ' . $client->id);
        _applySoloistMetadata($client, $lastSoloistMetadata) if $lastSoloistMetadata;
    }
    elsif ($activeWaveInputPlayer && $activeWaveInputPlayer eq $client->id) {
        $activeWaveInputPlayer = undef;
        $activeWaveInputClient = undef;
        delete $lastAppliedMetadataKey{$client->id};
        $log->info('LMS player left WaveInput playback');
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
    for my $size (qw(large xlarge default small)) {
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
    $lastSoloistMetadata = $meta;

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

    my $client = _masterClient($activeWaveInputClient);
    return unless $client && _isActiveWaveInput($client);
    _applySoloistMetadata($client, $meta);
}

# When Spotify starts playing on this Connect device, make sure the LMS player
# is actually streaming the WaveInput source. Never interrupts another source
# that is currently playing.
sub _resumeLmsForSpotify {
    return unless $spotifyPlaying && _sessionIsHere();
    my $client;
    if (my $id = $prefs->get('autoPlayPlayer')) {
        $client = Slim::Player::Client::getClient($id);
        $log->warn("Auto-play player $id is not connected to LMS") unless $client;
    }
    $client ||= $activeWaveInputClient;
    $client = _masterClient($client);
    return unless $client;

    my $isPlaying = eval { $client->isPlaying() } ? 1 : 0;
    my $onWavin = _isWaveInput($client);
    return if $isPlaying && $onWavin;
    if ($isPlaying) {
        $log->info('Spotify started, but LMS player ' . $client->name . ' is playing another source; leaving it alone');
        return;
    }

    $suppressTransportUntil{$client->id} = Time::HiRes::time() + 3;
    if ($onWavin) {
        $log->info('Spotify started; resuming WaveInput on ' . $client->name);
        $client->execute(['play']);
        return;
    }
    return unless $prefs->get('autoPlayPlayer');   # only switch sources when configured
    my $url = $prefs->get('wavinUrl') || DEFAULT_WAVIN_URL;
    return unless $url =~ /\Awavin:/i;
    $log->info('Spotify started; starting ' . $url . ' on ' . $client->name);
    $client->execute(['playlist', 'play', $url, string('PLUGIN_SOLOIST_NAME')]);
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

    $client->pluginData(soloistMetadata => {
        %{$meta}, displayTitle => $display, url => $logicalUrl || '',
    });
    for my $url (grep { defined $_ && length $_ } ($logicalUrl, $streamUrl)) {
        $metadataCache->set("remote_image_$url", $cover, 3600) if $cover;
    }
    eval {
        require Slim::Music::Info;
        # WaveInput assigns its display name with setTitle($wavinUrl, ...), so
        # replace the cached URL title as well as the runtime title.
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
    return unless _isActiveWaveInput($client);
    my $now = Time::HiRes::time();
    # Our own auto-resume issues LMS play commands; don't echo them back.
    return 1 if ($suppressTransportUntil{$client->id} || 0) > $now;
    unless (_sessionIsHere()) {
        $log->info("Not forwarding $command: the Spotify session is on another device");
        return 0;
    }
    my $key = $client->id . ':' . $command;
    return 1 if $lastTransportAt{$key} && $now - $lastTransportAt{$key} < 0.25;
    $lastTransportAt{$key} = $now;
    $log->info("LMS->Soloist transport: $command (player=" . $client->id . ')');
    require Plugins::Soloist::Control;
    Plugins::Soloist::Control->send($command);
}

sub _onPlaylistPause {
    my ($request) = @_;
    my $client = _masterClient($request->client());
    return unless _isActiveWaveInput($client);
    if ($request->isCommand([['playlist'], ['pause']])) {
        # Opening a wavin stream can emit a transient pause while LMS replaces
        # the previous playlist item. Don't echo that back to Spotify.
        if ($waveInputStartedAt{$client->id}
            && Time::HiRes::time() - $waveInputStartedAt{$client->id} < 3) {
            $log->debug('Ignoring transient LMS pause while WaveInput starts');
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
    return unless _isActiveWaveInput($client);
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
    return unless _isActiveWaveInput($client);
    my $mode = eval { $request->getRequest(1) } || '';
    return unless $mode eq 'play' || $mode eq 'pause';
    _sendTransport($client, $mode);
}

1;
