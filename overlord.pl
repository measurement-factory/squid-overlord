#!/usr/bin/perl -w

# Implements the server side of the Proxy Overlord Protocol:
# HTTP/1 POST requests for "/reset" URLs are translated into
# a Squid (re)start with the configuration from the POST body.
#
# This Overlord only supports basic HTTP/1 syntax and message
# composition rules to avoid being dependent on non-Core modules.


# These Core modules should be available in nearly all Perl installations.
use Carp;
use IO::Socket;
use IO::File;
use Getopt::Long;
use strict;
use warnings;
use English;

my $MyListeningPort = 13128;
my $SquidPrefix = "/usr/local/squid";

GetOptions(
    "port=i" => \$MyListeningPort,
    "prefix=s" => \$SquidPrefix,
) or die("usage: $0 [--listen <port>] [--prefix <Squid installation prefix>]\n");

my $SquidPidFilename = "$SquidPrefix/var/run/squid.pid";
my $SquidConfigFilename = "$SquidPrefix/etc/squid-overlord.conf"; # maintained by us
my $SquidExeFilename = "$SquidPrefix/sbin/squid";
my $SquidListeningPort = 3128;

# (re)start Squid form scratch with the given configuration
sub resetSquid
{
    my $config = shift;
    # warn("Resetting to:\n$config\n");

    &stopSquid() if &squidIsRunning();
    &writeSquidConfiguration($config);
    &startSquid();
}

sub stopSquid
{
    &shutdownSquid() if &squidIsRunning();
    warn("Squid is not running\n");
}

sub shutdownSquid
{
    my $pid = &squidPid();
    kill('SIGZERO', $pid) == 1 or die("cannot signal Squid ($pid): $EXTENDED_OS_ERROR\n");
    warn("shutting Squid ($pid) down...\n");
    kill('SIGINT', $pid) or return;

    &waitFor("deleted $SquidPidFilename", sub { ! &squidIsRunning() });
}

sub killSquid
{
    my $pid = &squidPid();
    kill('SIGZERO', $pid) == 1 or die("cannot signal Squid ($pid): $EXTENDED_OS_ERROR\n");
    warn("killing Squid ($pid) process...\n");
    kill('SIGKILL', $pid) == 1 or return;
    die("cannot kill Squid: $EXTENDED_OS_ERROR\n") if kill('SIGZERO', $pid) == 1;
}

sub writeSquidConfiguration
{
    my $config = shift;
    my $out = IO::File->new("> $SquidConfigFilename")
        or die("cannot create $SquidConfigFilename: $!\n");
    $out->print($config) or die("cannot write $SquidConfigFilename: $!\n");
    $out->close() or die("cannot finalize $SquidConfigFilename: $!\n");
    warn("created ", length($config), "-byte $SquidConfigFilename\n");
}

sub startSquid
{
    my $cmd = "$SquidExeFilename";
    $cmd .= " -C "; # prefer "raw" errors
    $cmd .= " -f $SquidConfigFilename";
    $cmd .= " > var/logs/squid.out 2>&1";
    warn("running: $cmd\n");
    system($cmd) == 0 or die("cannot start Squid: $!\n");

    &waitFor("running Squid", \&squidIsRunning);
    &waitFor("listening Squid", \&squidIsListening);
    warn("Squid is running\n");
}

sub waitFor
{
    my ($description, $goalFunction) = @_;

    for (my $iterations = 0; !&{$goalFunction}; ++$iterations) {
        warn("waiting for $description\n") if $iterations % 60 == 0;
        sleep(1);
    }
}

sub squidIsRunning() {
    # assume not running because there is no PID
    return 0 unless -e $SquidPidFilename;

    my $pid = &squidPid();
    my $killed = kill('SIGZERO', $pid);
    $killed = -1 unless defined $killed;

    # clearly running
    return 1 if $killed == 1;

    if ($killed == 0 && $!{ESRCH}) {
        warn("assuming Squid ($pid) has died");
        return 0;
    }

    warn("assume Squid ($pid) is running: $EXTENDED_OS_ERROR\n");
    return 1;
}

sub squidIsListening() {
    # TODO: Check that lsof works at all: -p $$

    # We do not specify the IP address part because
    # lsof -i@127.0.0.1 fails when Squid is listening on [::].
    # Should we configure Squid to listen on a special-to-us ipv4-only port?
    my $lsof = "lsof -Fn -w -i:$SquidListeningPort";
    if (system("$lsof > /dev/null 2>&1") == 0) {
        #warn("somebody is listening on port $SquidListeningPort\n");
        return 1;
    } else {
        #warn("nobody listens on port $SquidListeningPort\n");
        system($lsof); # will show usage error/problem if any
        return 0;
    }
}

sub squidPid
{
    my $in = IO::File->new("< $SquidPidFilename")
        or die("cannot open $SquidPidFilename: $!\n");
    my $pid = $in->getline() or die("cannot read $SquidConfigFilename: $!\n");
    $in->close();

    chomp($pid);
    die("malformed PID value: $pid") unless $pid =~ /^\d+$/;
    return int($pid);
}

# "parse" the client request and pass the details to the command-processing sub
sub handleClient
{
    my $client = shift;

    my $header = '';
    while (<$client>) {
        last if /^\s*$/;
        $header .= $_;
    }

    if ($header =~ m@^POST\s+/reset\s@s &&
        $header =~ m@^Content-Length:\s*(\d+)@im) {
        &resetSquid(&receiveBody($client, $1));
        &sendResponse($client, "200 OK", "");
        return;
    }

    die("unsupported Proxy Overlord Protocol request:\n$header\nstopped");
}

sub receiveBody
{
    my ($client, $bodyLength) = @_;

    my $body;
    my $result = $client->read($body, $bodyLength);
    die("cannot receive request body: $!") unless defined $result;
    die("received truncated request body: ",
        length $body, " vs. the expected $bodyLength bytes\n")
        if length $body != $bodyLength;
    return $body;
}

sub writeError
{
    my ($client, $error) = @_;
    warn("Error: $error\n");
    return &sendResponse($client, "555 External Server Error", $error);
}

sub sendResponse
{
    my ($client, $status, $body) = @_;

    warn("responding with $status\n");

    my $response = '';
    $response .= "HTTP/1.1 $status\r\n";
    $response .= "Connection: close\r\n";
    $response .= "Content-Length: " . (length $body) . "\r\n";
    $response .= "\r\n";
    $response .= $body;

    my $result = $client->send($response)
        or die("failed to write a $status response: $!\n");
    die("wrote truncated $status response") if $result != length $response;
}

chdir($SquidPrefix) or die("Cannot set working directory to $SquidPrefix: $!\n");

my $server = IO::Socket::INET->new(
    LocalPort => $MyListeningPort,
    Type      => SOCK_STREAM,
    Reuse     => 1,
    Listen    => 10, # SOMAXCONN
) or die("Cannot listen on on TCP port $MyListeningPort: $@\n");
warn("Overlord listens on port $MyListeningPort\n");

if (&squidIsRunning()) {
    warn("Squid listens on port $SquidListeningPort: ", (&squidIsListening() ? "yes" : "no"), "\n");
}

while (my $client = $server->accept()) {
    eval { &handleClient($client); };
    my $error = $@;
    eval { &writeError($client, $error) } if $error; # but swallow cascading errors
    close($client) or warn("cannot close client connection: $@\n");
}

exit(0);
