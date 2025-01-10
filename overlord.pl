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
use File::Basename;
# These are in Perl Core since Perl v5.14 (or earlier; see corelist -v 5.14.0)
use Data::Dumper;
use HTTP::Tiny;
use JSON::PP;

use v5.10; # for state variables, at least

my $MyListeningPort = 13128;
my $SquidPrefix = "/usr/local/squid";

GetOptions(
    "port=i" => \$MyListeningPort,
    "prefix=s" => \$SquidPrefix,
) or die(&usage());

my $SquidPidFilename = "$SquidPrefix/var/run/squid.pid";
my $SquidExeFilename = "$SquidPrefix/sbin/squid";
my $SquidValgrindSuppressionsFilename = "$SquidPrefix/etc/valgrind.supp";
my $SquidListeningPort = 3128;
# maintained by us
my $SquidConfigFilename = "$SquidPrefix/etc/squid-overlord.conf";
my $SquidLogsDirname = "$SquidPrefix/var/logs/overlord";
my $SquidCachesDirname = "$SquidPrefix/var/cache/overlord";
my $SquidConsoleLogFilename = "$SquidLogsDirname/squid-console.log";
my $SquidStartFilename = "$SquidLogsDirname/squid.start";

my $SupportedPopVersion = '11';

# Names of all supported POP request options (updated below).
# There is also 'config_' but that "internal" option is added by us.
my @SupportedOptionNames = ();

# /reset option
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

# /reset and /restart option
my $onameValgrindUse = 'valgrind-use';
push @SupportedOptionNames, $onameValgrindUse;

# /reset, /restart, and /reconfigure option
my $onameWorkerCount = 'worker-count';
push @SupportedOptionNames, $onameWorkerCount;

# /reset, /restart, and /reconfigure option
my $onameDiskerCount = 'disker-count';
push @SupportedOptionNames, $onameDiskerCount;

# /waitActiveRequests option
my $onameRequestPath = 'request-path';
push @SupportedOptionNames, $onameRequestPath;

# /waitActiveRequests option
my $onameActiveRequestsCount = 'active-requests-count';
push @SupportedOptionNames, $onameActiveRequestsCount;

my %SupportedOptionNameIndex = map { $_ => 1 } @SupportedOptionNames;

my $ValgrindIsPresent = &isValgrindPresent();

sub usage
{
    return <<"USAGE";
usage: $0 [option]...
  supported options:
  --listen <port>: Where to listed for POP commands from Daft [$MyListeningPort]
  --prefix <Squid installation prefix>: Where to find installed Squid files [$SquidPrefix]
USAGE
}

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
    warn("Resetting Squid\n");
    # warn("Resetting to:\n$config\n");

    &stopSquid($options) if &squidIsRunning();

    &writeSquidConfiguration($config);
    # Ensure log directory existence
    # and avoid polluting old logs with the upcoming squid-z activity.
    &resetLogs();
    &resetCaches() if $config =~ /cache_dir/; # needs writeSquidConfiguration()

    &startSquidInBackground($options);
}

# ==00:00:00:02.432 2834323== ERROR_BEGIN_
# ==00:00:00:02.432 2834323== 4 bytes in 1 blocks are definitely lost in loss record 8 of 631
# ==00:00:00:02.432 2834323==    at 0x4848899: malloc (vg_replace_malloc.c:381)
# ...
# ==00:00:00:02.432 2834323==    by 0x6D96D8: main (main.cc:1339)
# ==00:00:00:02.432 2834323==
# ==00:00:00:02.260 2969939== ERROR_END_
#
# Also extracts problematic LEAK SUMMARY records
sub extractValgrindErrors
{
    my ($logName, $lines) = @_;

    my $leakSummary = undef();

    my @records = ();
    my $record = undef();
    for (my $i = 0; $i <= $#{$lines}; ++$i) {
        # emulate `grep -n` output (when grep is searching through multiple files)
        my $line = sprintf("%s:%d:%s", $logName, $i, $lines->[$i]);

        if (defined $record) {
            if ($line =~ /\bERROR_END_\b/) {
                push @records, $record;
                $record = undef();
            } else {
                $record .= $line;
            }
        } else {
            if ($line =~ /\bERROR_BEGIN_\b/) {
                $record = '';
            }
            elsif ($line =~ /lost: [^0].* bytes in .* blocks/) {
                $leakSummary = '' unless defined $leakSummary;
                $leakSummary .= $line;
            }
        }
    }

    # in case the log ends with a truncated loss record
    push @records, $record if defined $record;

    push @records, $leakSummary if defined $leakSummary;

    return (@records);
}

sub valgrindStarted() {
    return 0 unless $ValgrindIsPresent;

    # XXX: These logs may be from a very old test. We can ping logged valgrind
    # kid process and then ignore old logs that are not backed by a process.
    my @logs = glob "$SquidLogsDirname/valgrind*.log";
    return @logs > 0;
}

sub allValgrindKidsExited() {
    while (glob "$SquidLogsDirname/valgrind*.log") {
        # TODO: Encapsulate this duplicated code.
        my $logName = $_;
        my $in = IO::File->new($logName, "r") or die("cannot read $logName: $!\n");
        my @lines = $in->getlines();

        next if grep { /\bFATAL:/ } @lines;
        next if grep { /ERROR SUMMARY: \d/ } @lines;

        # if this is not enough, we can also ping that valgrind kid process
        warn("assume valgrind is still logging to $logName\n");
        return 0;
    }

    return 1;
}

sub checkSquid
{
    my ($requireCompleteLogs) = @_;

    my $report = {};

    my $problems = `egrep -am10 '^[0-9./: ]+ kid[0-9]+[|] (WARNING|ERROR|FATAL|assertion)' $SquidLogsDirname/cache-*.log 2>&1`;
    # split into individual problems, removing the trailing LF from each problem
    $report->{problems} = [ split(/\n$|\n(?!\s)/s, $problems) ];

    while (glob "$SquidLogsDirname/valgrind*.log") {
        # TODO: Encapsulate this duplicated code.
        my $logName = $_;
        my $in = IO::File->new($logName, "r") or die("cannot read $logName: $!\n");
        my @lines = $in->getlines();

        if (my (@valgrindFatals) = grep { /\bFATAL:/ } @lines) {
            warn("FATALs in $_: $valgrindFatals[0]\n");
            push @{$report->{problems}}, @valgrindFatals;
        }

        if (my (@errorSummaries) = grep { /ERROR SUMMARY: \d/ } @lines) {
            if (my (@errorsInSummaries) = grep { /ERROR SUMMARY: [^0]/ } @errorSummaries) {
                warn("ERRORs in $logName: $errorsInSummaries[0]\n");
                my (@valgrindErrors) = &extractValgrindErrors($logName, \@lines);
                push @{$report->{problems}}, @valgrindErrors;
            }
            # else: OK, no errors in ERROR SUMMARY lines
        } elsif ($requireCompleteLogs) {
            # If there is no summary logged, Valgrind probably did not have a
            # chance to report memory leaks (if any).
            warn("ERROR: No ERROR SUMMARY in $logName\n");
            push @{$report->{problems}}, "$logName: Missing ERROR SUMMARY";
        }
    }

    warn("health problems: ", scalar(@{$report->{problems}}), "\n");
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

    &waitFor("no running Squid", sub { ! &squidIsRunning() });
}

sub reconfigurationLines
{
    my $stats = {};
    $stats->{reconfiguringLines} = `grep -aF 'Reconfiguring Squid Cache' $SquidLogsDirname/cache-*.log | wc -l`;
    $stats->{acceptingLines} = `grep -a 'Accepting .* connections' $SquidLogsDirname/cache-*.log | wc -l`;
    return $stats;
}

sub reconfigureSquid
{
    my ($options) = @_;
    my $running = &squidIsRunning() or
        die("cannot reconfigure a Squid instance that is not running");
    my $pid = $running->[0];
    my $signal = 'SIGHUP';

    my $statsBefore = &reconfigurationLines();

    kill('SIGZERO', $pid) == 1 or die("cannot signal Squid ($pid): $EXTENDED_OS_ERROR\n");
    warn("reconfiguring Squid (PID: $pid; signal: $signal)...\n");
    kill($signal, $pid) or return;

    my $workerCount = &requiredOption($onameWorkerCount, $options);
    my $diskerCount = &requiredOption($onameDiskerCount, $options);
    my $coordinatorCount = ($workerCount + $diskerCount > 1) ? 1 : 0;
    my $portCount = scalar expectedSquidListeningPorts($options);
    my $reconfigurationsExpected = $workerCount + $diskerCount + $coordinatorCount;
    my $listenersExpected = $workerCount * $portCount;

    &waitFor("reconfigured Squid", sub {
        my $statsAfter = &reconfigurationLines();

        die("shrinking reconfiguringLines; stopped") if $statsBefore->{reconfiguringLines} > $statsAfter->{reconfiguringLines};
        die("shrinking acceptingLines; stopped") if $statsBefore->{acceptingLines} > $statsAfter->{acceptingLines};
        return 0 if $statsBefore->{reconfiguringLines} == $statsAfter->{reconfiguringLines};
        return 0 if $statsBefore->{acceptingLines} == $statsAfter->{acceptingLines};

        my $reconfiguringNow = $statsAfter->{reconfiguringLines} - $statsBefore->{reconfiguringLines};
        die("too many reconfiguring now: $reconfiguringNow > $reconfigurationsExpected") if $reconfiguringNow > $reconfigurationsExpected;
        return 0 if $reconfiguringNow < $reconfigurationsExpected;

        my $acceptingNow = $statsAfter->{acceptingLines} - $statsBefore->{acceptingLines};
        die("too many accepting now: $acceptingNow > $listenersExpected") if $acceptingNow > $listenersExpected;
        return 0 if $acceptingNow < $listenersExpected;

        return 1;
    });
}

sub resetLogs
{
    &resetDir($SquidLogsDirname);
}

sub resetCaches
{
    my ($options) = @_;
    &resetDir($SquidCachesDirname);
    &runSquidInForeground($options, '-z');
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

    &startSquid_($options);
    &waitFor("running Squid", \&squidIsRunning);
    &waitFor("listening Squid", sub { return &squidIsListeningOnAllPorts($options); });
    &waitFor("Squid with all kids registered", sub { return &squidHasAllKids($options); });
    warn("Squid is running and ready\n");
}

sub runSquidInForeground
{
    my ($options, @extraOptions) = @_;
    &startSquid_($options, '--foreground', @extraOptions);
}

sub wrapperCommand_
{
    my ($options, @extraOptions) = @_;

    return "" unless exists $options->{$onameValgrindUse} && $options->{$onameValgrindUse};
    die("test requires valgrind use but this overlord environment lacks it") unless $ValgrindIsPresent;

    # no valgrind for auto-generated squid -z step, even if valgrind is
    # explicitly requested for primary squid execution
    return "" if grep { $_ eq '-z' } @extraOptions;

    my $wrapper = "valgrind
        --verbose
        --show-error-list=yes
        --error-markers=ERROR_BEGIN_,ERROR_END_
        --vgdb=no
        --trace-children=yes
        --child-silent-after-fork=no
        --num-callers=50
        --log-file=$SquidPrefix/var/logs/overlord/valgrind-%p.log
        --time-stamp=yes
        --leak-check=full
        --leak-resolution=high
        --show-reachable=no
        --track-origins=no
        --gen-suppressions=all
        --suppressions=$SquidValgrindSuppressionsFilename
    ";
    $wrapper =~ s/\s+/ /gs; # convert repeated spaces/newlines into a single space
    return $wrapper;
}


# common part for startSquidInBackground() and runSquidInForeground()
sub startSquid_
{
    my ($options, @extraOptions) = @_;

    my $cmd = "";
    # XXX: Cannot do that on Github Actions Ubuntu runner: Permission denied
    # $cmd .= "ulimit -c unlimited; "; # TODO: Detect and report core dumps.
    $cmd .= "ulimit -n 10240; ";

    $cmd .= "touch $SquidStartFilename; ";

# XXX: make conditional on something
# * This should probably be controlled (e.g., explicitly disabled) by tests
#   because running under valgrind slows things down quite a bit.
#
# * This should probably be controlled by an "Is valgrind installed?" check
#   (and disabled unless the test explicitly requires valgrind) because folks
#   might need to tests environments without valgrind installed.
#
    my $wrapperCommand = &wrapperCommand_($options, @extraOptions);
    my $startTarget = $wrapperCommand ? "valgrind-wrapped Squid" : "Squid";
    $cmd .= $wrapperCommand;

    $cmd .= " $SquidExeFilename";
    $cmd .= " -C "; # prefer "raw" errors
    $cmd .= " -f $SquidConfigFilename";
    $cmd .= ' ' . join(' ', @extraOptions) if @extraOptions;
    $cmd .= " > $SquidConsoleLogFilename 2>&1; ";

    $cmd .= 'squid_exit_code=$?; ';
    $cmd .= "rm -f $SquidStartFilename; ";
    $cmd .= 'exit $squid_exit_code';

    warn("running: $cmd\n");
    system($cmd) == 0 or die("cannot start $startTarget: $!\n" . &cluesFromLogs());
}

sub cluesFromLogs
{
    my $report = &checkSquid();
    return encode_json($report);
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

    if (!$EFFECTIVE_USER_ID) {
        my $parent = dirname($dirname);
        my $cmd = "chown --reference $parent $dirname";
        system($cmd) == 0 or die("cannot set ownership of the parent directory: $!\n" .
            "command: $cmd\n" .
            "stopped");
    }
}

sub waitFor
{
    my ($description, $goalFunction) = @_;

    warn("will be waiting for $description\n");
    for (my $iterations = 0; !&{$goalFunction}; ++$iterations) {
        warn("waiting for $description\n") if $iterations % 60 == 0;
        sleep(1);
    }
}

# returns [PID] if Squid is running (with the returned PID)
# returns undef() otherwise
sub squidIsRunning() {
    my $pid = &squidPid();

    if (!defined $pid) {
        warn("assume Squid is not running because there is no (PID in a stable) PID file\n");
        return undef();
    }

    my $killed = kill('SIGZERO', $pid);
    $killed = -1 unless defined $killed;

    if ($killed == 1) {
        warn("Squid ($pid) is definitely running\n");
        return [ $pid ];
    }

    if ($killed == 0 && $!{ESRCH}) {
        warn("assuming Squid ($pid) has died; removing its PID file");
        system("rm -f $SquidPidFilename") == 0 or die("cannot remove $SquidPidFilename: $EXTENDED_OS_ERROR\n");
        die("failed to remove $SquidPidFilename\n") if &squidPid();
        return undef();
    }

    warn("assume Squid ($pid) is running: $EXTENDED_OS_ERROR\n");
    return [ $pid ];
}

sub expectedSquidListeningPorts() {
    my ($options) = @_;
    die() unless $options;

    # We do not parse http_port lines because they may have ${process_number}
    # and/or may be affected by macros.
    my (@ports) = split(/\s*,\s*/, &requiredOption($onameListeningPorts, $options));
    die("cannot determine Squid listening ports") unless @ports;
    return (@ports);
}

sub squidIsListeningOnAllPorts() {
    my ($options) = @_;
    my @ports = &expectedSquidListeningPorts($options);
    return &squidIsListeningOn(@ports);
}

sub squidIsListeningOn() {
    my @ports = @_;
    die() unless @ports;
    die() unless defined $ports[0];

    my $cmd = "netstat --numeric --wide --listening --tcp";
    my $netstat = IO::File->new("$cmd |") or die("cannot start $cmd: $!\n");
    my @lines = $netstat->getlines() or die("cannot read from $cmd: $!\n");
    $netstat->close(); # often fails with "No child processes"

    foreach my $port (@ports) {
        # find :port in the first (out of two) columns containing ports
        my ($firstMatch) = grep { /:\Q$port\E\s.*:/ } @lines;
        return 0 unless defined $firstMatch;
    }
    return 1;
}

sub requiredOption() {
    my ($oname, $options) = @_;
    my $result = $options->{$oname};
    die("missing $oname in ", join(",", keys %{$options})) unless defined $result;
    return $result;
}

sub squidPid
{
    # optional argument: whether the file contents was empty a few seconds ago
    my ($wasEmpty) = @_;

    my $in = IO::File->new("< $SquidPidFilename");
    if (!$in) {
        # ENOENT is a common case not worth warning about
        die("no OS support for ENOENT") unless exists $OS_ERROR{ENOENT};
        if (!$OS_ERROR{ENOENT}) {
            warn("cannot open $SquidPidFilename: $!\n");
            return undef();
        }

        &waitFor("top process exit", sub { ! -e $SquidStartFilename });
        &waitFor("valgrind kids exit", sub { &allValgrindKidsExited() }) if &valgrindStarted();
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

sub waitActiveRequests
{
    my ($options) = @_;

    my $requestPath = $options->{$onameRequestPath};
    die("missing $onameRequestPath\n") unless defined $requestPath;
    my $activeRequestsCount = $options->{$onameActiveRequestsCount};
    die("missing $onameActiveRequestsCount\n") unless defined $activeRequestsCount;

    my ($path, $count) = @_;
    &waitFor("exactly $activeRequestsCount requests to become active", sub {
            &countMatchingActiveRequests($requestPath) == $activeRequestsCount });
}

# whether Squid has StoreEntries in SWAPOUT_WRITING state
sub squidHasSwapouts
{
    my $mgrPage = &getCacheManagerResponse('openfd_objects')->{content};
    return $mgrPage =~ /SWAPOUT_WRITING/;
}

sub countMatchingActiveRequests
{
    my $path = shift;
    my $mgrPage = &getCacheManagerResponse('active_requests')->{content};
    my @matches = $mgrPage =~ /^uri\s.*$path$/mg;
    return scalar @matches;
}

# whether all Squid kid processes have registered with Coordinator
# assumes that Squid is running and listening
sub squidHasAllKids
{
    my ($options) = @_;

    my $workersExpected = &requiredOption($onameWorkerCount, $options);
    my $diskersExpected = &requiredOption($onameDiskerCount, $options);

    # cache manager action selection criteria:
    # * non-aggregating or, to be more precise, contains a single kid-specific
    #   section for each reporting kid and no aggregated sections
    # * atomic (to reduce delays)
    # * available in any Squid build
    # * safe (i.e. unlikely to crash Squid)
    # * light (i.e. does not trigger a lot of work or debugging)
    my $action = 'events';

    # TODO: If there is a disker, we should (also) wait for kids to find the
    # disker strand (mtFindStrand). Is there a mgr page reflecting that state?

    my $mgrPage = &getCacheManagerResponse($action)->{content};

    # compute the number of closed kid-specific report sections
    my $kidSections = () = $mgrPage =~ /^([}] by kid\d+|[.]{3})/mg;

    if ($workersExpected + $diskersExpected <= 1) {
        # Non-SMP configuration: (0+0) or (1+0).
        # In legacy Squids, there should be no kid-specific sections.
        # In future YAML-reporting Squids, there should be one section.
        die("unexpected kid sections in non-SMP mode: ($workersExpected + $diskersExpected) < $kidSections near $mgrPage")
            unless $kidSections <= 1;
        return 1;
    } else {
        # SMP configuration. A kid-specific section for each worker and disker.
        die("unexpected kid sections in SMP mode; ($workersExpected + $diskersExpected) < $kidSections near $mgrPage")
            if ($workersExpected + $diskersExpected) < $kidSections;
        return (($workersExpected + $diskersExpected) == $kidSections) ? 1 : 0;
    }
}

# successful Http::Tiny response object for a given mgr:page ID
sub getCacheManagerResponse
{
    my ($pageId) = @_;
    die() unless defined $pageId;

    my $url = "http://127.0.0.1:3128/squid-internal-mgr/$pageId";
    my %extraHeaders = ("Cache-Control" => "no-store");
    warn("will send a cache manager request for $url\n");
    my $response = HTTP::Tiny->new->get($url, { headers => \%extraHeaders });
    warn("sent a cache manager request\n");
    die("Cache manager request failure:\n" .
        "Request URL: $url\n" .
        "Response status: $response->{status} ($response->{reason})\n" .
        Dumper($response->{headers}) . "\n" .
        $response->{content} . "\nnear")
        unless $response->{success} && $response->{status} == 200;

    return $response;
}

sub getAccessRecords
{
    # 1: countMatchingActiveRequests() should see its own mgr:active_requests
    # request; TODO: Should that function filter out its own request?
    &waitFor("all past requests to complete", sub {
        &countMatchingActiveRequests('.') <= 1 });

    warn("getting access records from $SquidLogsDirname/\n");
    my $records = {};
    while (glob "$SquidLogsDirname/access*.log") {
        my $logName = $_;
        my $in = IO::File->new($logName, "r") or die("cannot read $logName: $!\n");
        my @lines = $in->getlines();
        # TODO: Set a custom User-Agent to filter out our own requests.
        $records->{basename $logName} = [ grep { !/squid-internal-mgr/ } @lines ];
        warn("lines in $_: $#lines\n");
    }
    return $records;
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

    if ($header =~ m@^GET\s+\S*/executionEnvironment\s@s) {
        # reply without checkSquid() because logs dir may still be dirty/stale
        my $answer = { executionEnvironment => &executionEnvironment() };
        my $body = { minimal => 1, answer => $answer };
        return &sendOkResponse($client, $body);
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
        my $body = { health => &checkSquid("stopped") };
        &sendOkResponse($client, $body);
        return;
    }

    if ($header =~ m@^GET\s+\S*/restart\s@s) {
        my %options = &parseOptions($header);
        &stopSquid(\%options);
        &startSquidInBackground(\%options);
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/reconfigure\s@s) {
        my %options = &parseOptions($header);
        &reconfigureSquid(\%options);
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/getAccessRecords\s@s) {
        my $answer = { accessRecords => &getAccessRecords() };
        my $body = { health => &checkSquid(), answer => $answer };
        &sendOkResponse($client, $body);
        return;
    }

    if ($header =~ m@^GET\s+\S*/finishCaching\s@s) {
        &finishCaching();
        &sendOkResponse($client);
        return;
    }

    if ($header =~ m@^GET\s+\S*/waitActiveRequests\s@s) {
        my %options = &parseOptions($header);
        &waitActiveRequests(\%options);
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
    my ($client, $body) = @_;
    if (!$body) {
        $body = {};
        $body->{health} = &checkSquid();
        # no $body->{answer} by default
    }
    return &sendResponse($client, "200 OK", encode_json($body));
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

sub isValgrindPresent
{
    if (defined $SquidValgrindSuppressionsFilename && ! -e $SquidValgrindSuppressionsFilename) {
        warn("Valgrind suppression file for Squid not found at $SquidValgrindSuppressionsFilename");
        return 0;
    }

    if (system("valgrind --version") != 0) {
        warn("Cannot start valgrind");
        return 0;
    }

    # TODO: Check whether Squid was built with valgrind support.
    warn("Valgrind suppression file: $SquidValgrindSuppressionsFilename\n");
    return 1;
}

sub executionEnvironment
{
    my $ee = {};
    $ee->{'valgrindIsPresent'} = $ValgrindIsPresent;
    warn("Summarized execution environment: " . Dumper($ee));
    return $ee;
}

sub myWarn
{
    my ($message) = @_;

    my $now = time();

    state $lastMessageTime = $now;

    my $diff = $now - $lastMessageTime;
    use POSIX qw(strftime);
    # XXX: "Z" suffix stands for UTC, but gmtime() returns GMT, not UTC.
    # How to get UTC using Perl Core modules only?
    my $nowStr = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($now));
    printf(STDERR "%s +%ds| %-6d | %s", $nowStr, $diff, $$, $message);
    $lastMessageTime = $now;
}

$SIG{'__WARN__'} = \&myWarn;

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
