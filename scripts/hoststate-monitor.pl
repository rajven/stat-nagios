#!/usr/bin/perl

#
# Copyright (C) Roman Dmitiriev, rnd@rajven.ru
#

use FindBin '$Bin';
use lib "$Bin";
use strict;
use Time::Local;
use FileHandle;
use Rstat::config;
use Rstat::mysql;
use Rstat::main;
use Rstat::nagios;
use Data::Dumper;
use Time::Local;
use Date::Parse;
use Getopt::Long;
use Proc::Daemon;
use Cwd;

my $pf = '/var/run/nagios/hoststate-monitor.pid';
my $socket_path='/var/spool/nagios/hoststate.socket';

my $daemon = Proc::Daemon->new(
        pid_file => $pf,
        work_dir => $HOME_DIR
);

# are you running?  Returns 0 if not.
my $pid = $daemon->Status($pf);

my $daemonize = 1;

GetOptions(
    'daemon!' => \$daemonize,
    "help"    => \&usage,
    "reload"  => \&reload,
    "restart" => \&restart,
    "start"   => \&run,
    "status"  => \&status,
    "stop"    => \&stop
) or &usage;

exit(0);

sub stop {
        if ($pid) {
                print "Stopping pid $pid...";
                if ($daemon->Kill_Daemon($pf)) {
                        print "Successfully stopped.\n";
                } else {
                        print "Could not find $pid.  Was it running?\n";
                }
         } else {
                print "Not running, nothing to stop.\n";
         }
}

sub status {
        if ($pid) {
                print "Running with pid $pid.\n";
        } else {
                print "Not running.\n";
        }
}

sub run {
if (!$pid) {
    print "Starting...";
    if ($daemonize) {
        # when Init happens, everything under it runs in the child process.
        # this is important when dealing with file handles, due to the fact
        # Proc::Daemon shuts down all open file handles when Init happens.
        # Keep this in mind when laying out your program, particularly if
        # you use filehandles.
        $daemon->Init;
        }

setpriority(0,0,19);

while(1) {
eval {

my $hdb = DBI->connect("dbi:mysql:database=$DBNAME;host=$DBHOST","$DBUSER","$DBPASS");
if ( !defined $hdb ) { die "Cannot connect to mySQL server: $DBI::errstr\n"; }

open(hoststate,$socket_path) || die("Error open fifo socket $socket_path: $!");

while (my $logline = <hoststate>) {
next unless defined $logline;
chomp($logline);
my ($date,$hoststate,$hoststatetype,$hostname,$hostip,$hostid,$hosttype,$svc_control)= split (/\|/, $logline);
next if (!$hostid);

if (time()-$last_refresh_config>=60) { init_option($hdb); }

if (!$svc_control) { $svc_control=0; }

if ($hoststate=~/UNREACHABLE/i) { $hoststate='DOWN'; }

my $old_state = 'HARDDOWN';

my $device;
if ($hosttype=~/device/i) {
    $device = get_record_sql($hdb,'SELECT nagios_status FROM devices WHERE id='.$hostid);
    } else {
    $device = get_record_sql($hdb,'SELECT nagios_status,nagios_handler FROM User_auth WHERE id='.$hostid);
    }

if ($device->{nagios_status}) { $old_state = $device->{nagios_status}; }

db_log_debug($hdb,"Get old for $hostname [$hostip] id: $hostid type: $hosttype => state: $old_state");
if ($hoststate eq "DOWN") { $hoststate=$hoststatetype.$hoststate; }
db_log_debug($hdb,"Now for $hostname [$hostip] id: $hostid type: $hosttype => state: $hoststate");

if ($hoststate ne $old_state) {
    #disable child
    my $full_action = ($svc_control eq 2);
    #Change device state
    db_log_verbose($hdb,"Host changed! $hostname [$hostip] => $hoststate, old: $old_state");
    my $ip_aton=StrToIp($hostip);
    if ($hosttype=~/device/i) {
            do_sql($hdb,'UPDATE devices SET nagios_status="'.$hoststate.'" WHERE id='.$hostid);
            do_sql($hdb,'UPDATE User_auth SET nagios_status="'.$hoststate.'" WHERE deleted=0 AND ip_int='.$ip_aton);
            } else {
            do_sql($hdb,'UPDATE User_auth SET nagios_status="'.$hoststate.'" WHERE id='.$hostid);
            }
    if ($hoststate=~/UP/i) { nagios_host_svc_enable($hostname,1); }
    if ($hoststate=~/SOFTDOWN/i) { if ($svc_control) { nagios_host_svc_disable($hostname,$full_action); } }
    if ($hoststate=~/HARDDOWN/i) {
        if ($svc_control) { nagios_host_svc_disable($hostname,$full_action); }
        if ($device->{nagios_handler}) {
            db_log_info($hdb,"Event handler $device->{nagios_handler} for $hostname [$hostip] => $hoststate found!");
            if ($device->{nagios_handler}=~/restart-port/i) {
                    my $run_cmd = "/usr/local/scripts/restart_port_snmp.pl $hostip & ";
                    db_log_info($hdb,"Nagios eventhandler restart-port started for ip: $hostip");
                    db_log_info($hdb,"Run handler: $run_cmd");
                    system($run_cmd);
                    }
            } else {
            db_log_debug($hdb,"Event handler for $hostname [$hostip] => $hoststate not found.");
            }
        }
    }
}
close(hoststate);
};
if ($@) { log_error("Exception found: $@"); sleep(60); }
}
    } else {
        log_error("Already Running with pid $pid");
    }
}

sub usage {
    print "usage: hoststate-monitor.pl (start|stop|status|restart)\n";
    exit(0);
}

sub reload {
    print "reload process not implemented.\n";
}

sub restart {
    stop;
    run;
}
