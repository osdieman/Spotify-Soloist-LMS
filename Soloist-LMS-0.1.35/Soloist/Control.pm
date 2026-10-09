package Plugins::Soloist::Control;

# Transport commands to Soloist. They always go over the persistent,
# non-blocking WebSocket in Metadata.pm. Up to 0.1.27 there was a fallback
# that opened a one-shot blocking connection (connect + handshake + write,
# each able to wait about a second); that could stall LMS, so it is gone.
# If Soloist isn't connected the command fails at once and a reconnect is
# requested.

use strict;
use warnings;
use Slim::Utils::Log;
use Plugins::Soloist::Metadata;

my $log = logger('plugin.soloist');
my $lastError = '';
sub lastError { return $lastError; }

sub send {
    my ($class, $command, $extra) = @_;
    $lastError = '';
    return _fail("Unsupported Soloist command: $command")
        unless $command =~ /\A(?:play|pause|skip_next|skip_prev|seek)\z/;
    my %payload = (type => 'command', command => $command);
    if (ref($extra) eq 'HASH') {
        $payload{$_} = $extra->{$_} for keys %{$extra};
    }
    if (Plugins::Soloist::Metadata->sendPayload(\%payload)) {
        $log->debug("Command sent to Soloist: $command");
        return 1;
    }
    Plugins::Soloist::Metadata->kick();
    return _fail("Not connected to Soloist (is it running?); $command not sent");
}

sub _fail { $lastError = $_[0]; $log->warn($lastError); return 0; }

1;
