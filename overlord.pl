#!/usr/bin/perl -w

# Implements the server side of the Proxy Overlord Protocol (POP):
# HTTP/1 requests for "/reset", "/check", and other POP URLs
# are translated into a Squid instance management operations.
#
# This Overlord only supports basic HTTP/1 syntax and message
# composition rules to avoid being dependent on non-Core modules.


# These Core modules should be available in nearly all Perl installations.
use IO::Socket;
use IO::File;
use POSIX qw(:sys_wait_h);
use Getopt::Long;
use strict;
use warnings;
use English;
# These are in Perl Core since Perl v5.14: corelist -v 5.14.0
use JSON::PP;
use HTTP::Tiny;


my $MyListeningPort = 13128;
my $SquidPrefix = "/usr/local/squid";

GetOptions(
    "port=i" => \$MyListeningPort,
    "prefix=s" => \$SquidPrefix,
) or die("usage: $0 [--listen <port>] [--prefix <Squid installation prefix>]\n");

my $SquidPidFilename = "$SquidPrefix/var/run/squid.pid";
my $SquidExeFilename = "$SquidPrefix/sbin/squid";
my $SquidListeningPort = 3128;
# maintained by us
my $SquidConfigFilename = "$SquidPrefix/etc/squid-overlord.conf";
my $SquidLogsDirname = "$SquidPrefix/var/logs/overlord";
my $SquidCachesDirname = "$SquidPrefix/var/cache/overlord";
my $SquidOutFilename = "$SquidLogsDirname/squid.out";

my $SupportedPopVersion = '4';

# Names of all supported POP request options (updated below).
# There is also 'config_' but that "internal" option is added by us.
my @SupportedOptionNames = ();

# /start option
my $onameListeningPorts = 'listening-ports';
push @SupportedOptionNames, $onameListeningPorts;

# /stop (and /restart) option
my $onameShutdownManner = 'shutdown-manner';
push @SupportedOptionNames, $onameShutdownManner;
my %SignalsByShutdownManner = (
    'gracefully' => 'SIGTERM',
    'urgently' => 'SIGINT',
    'immediately' => '-SIGKILL', # sent to the entire process group
);
my $OptStopDefault = 'immediately';
die() unless exists $SignalsByShutdownManner{$OptStopDefault};

my %SupportedOptionNameIndex = map { $_ => 1 } @SupportedOptionNames;

# computes kill() signal name based on request $options
sub shutdownSignalFromOptions
{
    my ($options) = @_;

    my $manner = $options->{$onameShutdownManner};
    $manner = $OptStopDefault unless defined $manner;

    my $signal = $SignalsByShutdownManner{$manner};
    die("unsupported $onameShutdownManner: $manner\n") unless defined $signal;
    return $signal;
}

# (re)start Squid form scratch with the given configuration
sub resetSquid
{
    my ($options) = @_;
    my $config = $options->{config_};
    # warn("Resetting to:\n$config\n");

    &stopSquid($options) if &squidIsRunning();

    &writeSquidConfiguration($config);
    # Ensure log directory existence
    # and avoid polluting old logs with the upcoming squid-z activity.
    &resetLogs();
    &resetCaches() if $config =~ /cache_dir/; # needs writeSquidConfiguration()

    &startSquidInBackground($options);
}

sub checkSquid
{
    my $report = {};

    $report->{problems} = `egrep -am10 '^[0-9./: ]+ kid[0-9]+[|] (WARNING|ERROR|assertion)' $SquidLogsDirname/cache-*.log 2>&1`;
    $report->{problems} = '' unless $report->{problems} =~ /\S/;

    my $xactLogged = `cat $SquidLogsDirname/access-*.log | wc -l`;
    $xactLogged =~ s/^\s+|\s+$//sg; # remove leading and trailing whitespace
    $xactLogged = 0 unless $xactLogged =~ /\S/;
    $report->{transactionCount} = $xactLogged =~ /^\d+$/s ? int($xactLogged) : $xactLogged;

    return $report;
}

sub stopSquid
{
    my ($options) = @_;
    my $running = &squidIsRunning();
    &shutdownSquid($running->[0], $options) if $running;
    warn("Squid is not running\n");
}

sub shutdownSquid
{
    my ($pid, $options) = @_;
    die() unless defined $pid;
    die() unless defined $options;

    my $signal = &shutdownSignalFromOptions($options);

    kill('SIGZERO', $pid) == 1 or die("cannot signal Squid ($pid): $EXTENDED_OS_ERROR\n");
    warn("shutting Squid ($pid) down (with $signal)...\n");
    kill($signal, $pid) or return;

    &waitFor("deleted $SquidPidFilename", sub { ! &squidIsRunning() });
}

sub resetLogs
{
    &resetDir($SquidLogsDirname);
}

sub resetCaches
{
    &resetDir($SquidCachesDirname);
    &runSquidInForeground('-z');
    # Give tests new logs, without this past squid-z activity.
    &resetLogs();
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

sub startSquidInBackground
{
    my ($options) = @_;

    &startSquid_();
    &waitFor("running Squid", \&squidIsRunning);
    &waitFor("listening Squid", sub { return &squidIsListeningOnAllPorts($options); });
    warn("Squid is listening\n");
}

sub runSquidInForeground
{
    my @extraOptions = @_;
    &startSquid_('--foreground', @extraOptions);
}

# common part for startSquidInBackground() and runSquidInForeground()
sub startSquid_
{
    my @extraOptions = @_;

    my $cmd = "";
    # XXX: Cannot do that on Github Actions Ubuntu runner: Permission denied
    # $cmd .= "ulimit -c unlimited; "; # TODO: Detect and report core dumps.
    $cmd .= "ulimit -n 10240; ";
    $cmd .= " $SquidExeFilename";
    $cmd .= " -C "; # prefer "raw" errors
    $cmd .= " -f $SquidConfigFilename";
    $cmd .= ' ' . join(' ', @extraOptions) if @extraOptions;
    $cmd .= " > $SquidOutFilename 2>&1";
    warn("running: $cmd\n");
    system($cmd) == 0 or die("cannot start Squid: $!\n".
        &optionalContents($SquidOutFilename, 1));
}

sub optionalContents
{
    my ($fname, $decorate) = @_;
    my $in = IO::File->new($fname, "r") or return '';
    my $buf;
    $in->read($buf, 10*1024) or return '';
    return '' unless defined $buf;
    return $buf unless $decorate;
    return "$fname contains:\n$buf\n";
}

# backs up the given file (including directory) if it exists
sub backupFile
{
    my ($current, $backup) = @_;
    if (-e $current) {
        system("rm -r $backup") if -e $backup; # and ignore errors
        system("mv -T $current $backup") == 0
            or die("cannot rename $current to $backup\n");
    }
}

# (backs up and re)creates the given directory
sub resetDir
{
    my ($dirname) = @_;

    # Two backup levels are maintained, one for old logs, and one for -z logs.
    &backupFile("$dirname.1", "$dirname.2");
    &backupFile("$dirname", "$dirname.1");
    mkdir($dirname)
        or die("cannot create $dirname directory: $!");
}

sub waitFor
{
    my ($description, $goalFunction) = @_;

    for (my $iterations = 0; !&{$goalFunction}; ++$iterations) {
        warn("waiting for $description\n") if $iterations % 60 == 0;
        sleep(1);
    }
}

# returns [PID] if Squid is running (with the returned PID)
# returns undef() otherwise
sub squidIsRunning() {
    my $pid = &squidPid();

    # assume not running because there is no (PID in a stable) PID file
    return undef() unless defined $pid;

    my $killed = kill('SIGZERO', $pid);
    $killed = -1 unless defined $killed;

    # clearly running
    return [ $pid ] if $killed == 1;

    if ($killed == 0 && $!{ESRCH}) {
        warn("assuming Squid ($pid) has died");
        return undef();
    }

    warn("assume Squid ($pid) is running: $EXTENDED_OS_ERROR\n");
    return [ $pid ];
}

sub squidIsListeningOnAllPorts() {
    my ($options) = @_;

    # We do not parse http_port lines because they may have ${process_number}
    # and/or may be affected by macros.
    my $pname = 'listening-ports';
    die("missing $pname in ", join(",", keys %{$options})) unless defined $options->{$pname};
    my (@ports) = split(/\s*,\s*/, $options->{$pname});
    die("cannot determine Squid listening ports") unless @ports;

    foreach my $port (@ports) {
        return 0 unless &squidIsListeningOn($port);
    }
    return 1;
}

sub squidIsListeningOn() {
    my ($port) = @_;
    die() unless defined $port;

    # TODO: Check that lsof works at all: -p $$

    # We do not specify the IP address part because
    # lsof -i@127.0.0.1 fails when Squid is listening on [::].
    # Should we configure Squid to listen on a special-to-us ipv4-only port?
    my $lsof = "lsof -Fn -w -i:$port";
    if (system("$lsof > /dev/null 2>&1") == 0) {
        #warn("somebody is listening on port $port\n");
        return 1;
    } else {
        #warn("nobody listens on port $port\n");
        system($lsof); # will show usage error/problem if any
        return 0;
    }
}

sub squidPid
{
    # optional argument: whether the file contents was empty a few seconds ago
    my ($wasEmpty) = @_;

    my $in = IO::File->new("< $SquidPidFilename");
    if (!$in) {
        # ENOENT is a common case not worth warning about
        die("no OS support for ENOENT") unless exists $OS_ERROR{ENOENT};
        warn("cannot open $SquidPidFilename: $!\n") unless $OS_ERROR{ENOENT};
        return undef();
    }

    undef $!;
    if (defined(my $pid = $in->getline())) {
        $in->close();
        die("missing new line in $SquidPidFilename containing just '$pid'") unless chomp($pid) > 0;
        die("malformed PID value $pid") unless $pid =~ /^\d+$/;
        return int($pid);
    }

    die("cannot read $SquidPidFilename: $!\n") if $!;

    # empty PID file

    if ($wasEmpty) {
        warn("stable but empty $SquidPidFilename; assuming no running Squid\n");
        return undef();
    }

    warn("waiting to give Squid a chance to finish writing its PID file: $SquidPidFilename\n");
    sleep(5);
    return &squidPid(1);
}

# Should wait for all caching activity to stop, but currently only tracks
# swapout activity. TODO: openfd_objects or another cache manager action
# should account for (existing at the time of the first request) StoreEntry
# objects that may _start_ caching as well as memory caching.
sub finishCaching
{
    &waitFor("swapouts gone", sub { ! &squidHasSwapouts() });
}

# whether Squid has StoreEntries in SWAPOUT_WRITING state
sub squidHasSwapouts
{
    # XXX: Require listening-ports
    my $url = 'http://127.0.0.1:3128/squid-internal-mgr/openfd_objects';
    my $response = HTTP::Tiny->new->get($url);
    die("Cache manager request failure:\n" .
        "Request URL: $url\n" .
        "Response status: $response->{status} ($response->{reason})\n" .
        $response->{content} . "\nnear")
        unless $response->{success} && $response->{status} == 200;

    return $response->{content} =~ /SWAPOUT_WRITING/;
}

sub parseOptions
{
    my ($header) = @_;

    my %rawOptions = ($header =~ m@^Overlord-(\S+):\s*([^\r\n]*)@img);
    # convert keys to lowercase (so that we know what case they are in)
    my %options = map { lc($_) => $rawOptions{$_} } keys %rawOptions;
    foreach my $name (keys %options) {
        die("unsupported POP option $name in:\n$header\n")
            unless exists $SupportedOptionNameIndex{$name};
    }
    return %options;
}

# "parse" the client request and pass the details to the command-processing sub
sub handleClient
{
    my $client = shift;

    my $header = '';
    my $sawCrLf = 0;
    while (<$client>) {
        $sawCrLf = 1 if /^\s*$/;
        last if $sawCrLf;
        $header .= $_;
    }

    die("client disconnected before sending the request\n") unless length $header;
    die("client disconnected before completing the request header:\$header\n") unless $sawCrLf;

    if ($header =~ m@^Pop-Version:\s*(\S*)@im) {
        die("unsupported Proxy Overlord Protocol version $1 in:\n$header\n") unless $1 eq $SupportedPopVersion;
    } else {
        die("unsupported Proxy Overlord Protocol version 1 in:\n$header\n");
    }

    if ($header =~ m@^POST\s+\S*/reset\s@s &&
        $header =~ m@^Content-Length:\s*(\d+)@im) {
        my $length = $1;
        my %options = &parseOptions($header);

        $options{config_} = &receiveBody($client, $length);
        &resetSquid(\%options);
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/check\s@s) {
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/stop\s@s) {
        my %options = &parseOptions($header);
        &stopSquid(\%options);
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/restart\s@s) {
        my %options = &parseOptions($header);
        &stopSquid(\%options);
        &startSquidInBackground(\%options);
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/finishCaching\s@s) {
        &finishCaching();
        &sendOkResponse($client);
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

sub sendOkResponse
{
    my ($client) = @_;
    my $report = &checkSquid();
    return &sendResponse($client, "200 OK", encode_json($report));
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

sub handleClientOrWriteError
{
    my $client = shift;

    eval { &handleClient($client); };
    my $error = $@;
    eval { &writeError($client, $error) } if $error; # but swallow cascading errors

    close($client) or warn("cannot close client connection: $@\n");

    die($error) if $error;
    return 0;
}

# from "man perlipc"
sub reaper {
    local $!; # do not let waitpid() overwrite current error
    while ((my $pid = waitpid(-1, WNOHANG)) > 0 && WIFEXITED($CHILD_ERROR)) {
        my $how = $CHILD_ERROR ? " with error code $CHILD_ERROR" : "";
        warn("child $pid exited$how\n");
    }
    $SIG{'CHLD'} = \&reaper;
}

sub spawn
{
    my $code = shift;
    my $pid = fork();
    die("cannot fork: $!") unless defined($pid);
    return $pid if $pid; # parent
    warn("child $$ started\n");
    exit($code->());
}

chdir($SquidPrefix) or die("Cannot set working directory to $SquidPrefix: $!\n");

my $server = IO::Socket::INET->new(
    LocalPort => $MyListeningPort,
    Type      => SOCK_STREAM,
    Reuse     => 1,
    Listen    => 10, # SOMAXCONN
) or die("Cannot listen on on TCP port $MyListeningPort: $@\n");
warn("Overlord v$SupportedPopVersion listens on port $MyListeningPort\n");

if (&squidIsRunning()) {
    warn("Squid listens on port $SquidListeningPort: ",
        (&squidIsListeningOn($SquidListeningPort) ? "yes" : "no"),
        "\n");
}

$SIG{'CHLD'} = \&reaper;

while (1) {
    my $client = $server->accept() or do {
        next if $OS_ERROR{EINTR};
        die("accept failure: $!, stopped");
    };

    my $child = &spawn( sub { &handleClientOrWriteError($client); } );

    my $timeout = 60; # seconds
    # imprecise poor man's alarm() that is compatible with sleep()
    for (my $seconds = 0; $seconds < $timeout; ++$seconds) {
        last unless kill(0, $child);
        sleep(1);
    }

    if (kill(0, $child)) {
        warn("$$ killing kid $child that did not finish in $timeout seconds\n");
        kill('SIGTERM', $child) or warn("kill failure: $!");
    }

    close($client); # may already be closed
}

die("unreachable code reached, stopped");
