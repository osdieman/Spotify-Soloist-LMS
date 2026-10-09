package Plugins::Soloist::Settings;

use strict;
use warnings;
use utf8;    # literal non-ASCII text in this file is characters, not bytes
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::HTTP::CSRF;

my $prefs = preferences('plugin.soloist');
my $log = logger('plugin.soloist');
my $page = 'plugins/Soloist/settings/basic.html';

my @TEXT_PREFS = qw(soloistPath shimDir apiKeyFile playbackDevice deviceName dataDir cacheDir wsAddress captureDevice autoPlayPlayer);

sub new { shift->SUPER::new(@_); }
sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_SOLOIST_NAME'); }
sub needsClient { 0; }
sub page { Slim::Web::HTTP::CSRF->protectURI($page); }
sub prefs {
    return ($prefs, qw(autoStart shimDiagnostics appStartsPlayback keepDelayLow measureSource stallWatchdog
        maxTlengthMs initialVolume cacheSize captureBufferMs), @TEXT_PREFS);
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    # The API key arrives in its own field, never as a pref. Take it out of
    # the parameters straight away so it can't end up anywhere else.
    my $newKey = delete $paramRef->{soloistApiKeyInput};

    if ($paramRef->{saveSettings}) {
        # HTML checkboxes are omitted when unchecked; normalize explicitly.
        for my $name (qw(autoStart shimDiagnostics appStartsPlayback keepDelayLow measureSource)) {
            $paramRef->{"pref_$name"} = $paramRef->{"pref_$name"} ? 1 : 0;
        }
        for my $name (@TEXT_PREFS) {
            my $key = "pref_$name";
            my $value = defined $paramRef->{$key} ? $paramRef->{$key} : '';
            $value =~ s/[\x00-\x1f\x7f]//g;
            $value =~ s/^\s+|\s+$//g;
            $paramRef->{$key} = substr($value, 0, 1024);
        }
        $paramRef->{pref_deviceName} = substr($paramRef->{pref_deviceName}, 0, 64);

        my %limits = (
            maxTlengthMs  => [500, 50, 5000],
            initialVolume => [100, 0, 100],
            cacheSize     => [100, 0, 10000],
            captureBufferMs => [2000, 200, 4000],
        );
        for my $name (keys %limits) {
            my ($default, $min, $max) = @{$limits{$name}};
            my $key = "pref_$name";
            my $value = $paramRef->{$key} // '';
            $value = $default unless $value =~ /^\d+$/ && $value >= $min && $value <= $max;
            $paramRef->{$key} = int($value);
        }

        my ($wsHost, $wsPort) = ($paramRef->{pref_wsAddress} || '') =~ /\A(127\.0\.0\.1|localhost):(\d{1,5})\z/;
        $paramRef->{pref_wsAddress} = '127.0.0.1:9878'
            unless $wsHost && $wsPort >= 1 && $wsPort < 65536;

        $paramRef->{pref_captureDevice} = 'plughw:CARD=Loopback,DEV=1,SUBDEV=0'
            unless $paramRef->{pref_captureDevice} =~ /\A[\w:=,.\-]+\z/;

        $paramRef->{pref_autoPlayPlayer} = ''
            unless $paramRef->{pref_autoPlayPlayer} =~ /\A[0-9a-fA-F:.\-]{0,64}\z/;

        $paramRef->{pref_stallWatchdog} = 2
            unless defined $paramRef->{pref_stallWatchdog} && $paramRef->{pref_stallWatchdog} =~ /\A[012]\z/;

        for my $name (qw(soloistPath shimDir apiKeyFile dataDir cacheDir)) {
            my $value = $paramRef->{"pref_$name"};
            if (length $value && $value !~ m{\A/}) {
                $paramRef->{warning} .= "Path for $name must be absolute; previous value kept. ";
                $paramRef->{"pref_$name"} = $prefs->get($name);
            }
        }

        if (defined $newKey && $newKey =~ /\S/) {
            require Plugins::Soloist::Manager;
            my $path = $paramRef->{pref_apiKeyFile} || $prefs->get('apiKeyFile');
            if (Plugins::Soloist::Manager->saveKey($newKey, $path)) {
                $paramRef->{keyMessage} = Slim::Utils::Strings::string('PLUGIN_SOLOIST_KEY_SAVED');
            }
            else {
                $paramRef->{keyError} = Plugins::Soloist::Manager->lastError();
            }
        }
    }
    undef $newKey;

    if (my $action = $paramRef->{soloistAction}) {
        require Plugins::Soloist::Manager;
        require Plugins::Soloist::Control;
        my %actions = (
            start   => [sub { Plugins::Soloist::Manager->start() },   'Soloist is starting…', 'manager'],
            stop    => [sub { Plugins::Soloist::Manager->stop() },    'Soloist is stopping…', 'manager'],
            restart => [sub { Plugins::Soloist::Manager->restart() }, 'Soloist is restarting…', 'manager'],
            play    => [sub { Plugins::Soloist::Control->send('play') },      'Play sent.',     'control'],
            pause   => [sub { Plugins::Soloist::Control->send('pause') },     'Pause sent.',    'control'],
            next    => [sub { Plugins::Soloist::Control->send('skip_next') }, 'Next sent.',     'control'],
            prev    => [sub { Plugins::Soloist::Control->send('skip_prev') }, 'Previous sent.', 'control'],
        );
        if (my $entry = $actions{$action}) {
            my ($run, $okMessage, $kind) = @{$entry};
            my $ok = eval { $run->() };
            my $exception = $@;
            my $reason = $kind eq 'manager'
                ? Plugins::Soloist::Manager->lastError()
                : Plugins::Soloist::Control->lastError();
            $reason ||= $exception unless $ok;
            $paramRef->{actionMessage} = $ok ? $okMessage : ($reason || "Action '$action' failed.");
            $log->warn("Settings action $action failed: $exception") if $exception;
        }
    }

    require Plugins::Soloist::Manager;
    my $state = Plugins::Soloist::Manager->status();
    $paramRef->{serviceRunning}  = $state->{running} ? 1 : 0;
    $paramRef->{serviceStarting} = $state->{starting} ? 1 : 0;
    $paramRef->{serviceStopping} = $state->{stopping} ? 1 : 0;
    $paramRef->{servicePid}      = $state->{pid} || '';
    $paramRef->{serviceError}    = Plugins::Soloist::Manager->lastError();
    $paramRef->{logTail}         = Plugins::Soloist::Manager->logTail();
    $paramRef->{helpers}         = $state->{helpers} || [];
    $paramRef->{serviceExpired}  = $state->{expired};
    require Plugins::Soloist::Plugin;
    for my $client (Slim::Player::Client::clients()) {
        my $d = Plugins::Soloist::Plugin->delayDetails($client) or next;
        $paramRef->{delayText} = sprintf('%.1f s (%s)', $d->{delay}, $client->name)
            . (defined $d->{buffers} ? sprintf(' · in player buffers %.1f s', $d->{buffers}) : '')
            . (defined $d->{elapsed} ? sprintf(' · by elapsed time %.1f s', $d->{elapsed}) : '');
        last;
    }
    $paramRef->{keyStatus}       = Plugins::Soloist::Manager->keyStatus();
    $paramRef->{expiryHint}      = $state->{running} ? '' : Plugins::Soloist::Manager->expiryHint();
    require Plugins::Soloist::Watchdog;
    $paramRef->{watchdog}        = Plugins::Soloist::Watchdog->status();
    $paramRef->{players} = [
        map  { { id => $_->id, name => $_->name } }
        sort { lc($a->name) cmp lc($b->name) }
        Slim::Player::Client::clients()
    ];
    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;
