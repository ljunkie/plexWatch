#!/usr/bin/perl 
use strict;
use POSIX qw(setsid);
use Fcntl qw(:flock);

my $plexWatch_script = '/opt/plexWatch/plexWatch.pl';


###########################################################################
my $debug = 0;
my $script_fh;
&CheckLock;
chdir '/';
umask 0;


#open STDIN, '/dev/null';
#open STDERR, '>/dev/null';
#open STDOUT, '>/dev/null';
defined(my $pid = fork);
exit if $pid;
close STDIN;
close STDOUT;
close STDERR;

setsid or die "Can't start a new session: $!";
umask(0027); # create files with perms -rw-r----- 
chdir '/' or die "Can't chdir to /: $!";

open STDIN,  '<', '/dev/null' or die $!;
open STDOUT, '>', '/dev/null' or die $!;
open STDERR, '>>', '/tmp/plexWatch.log';

setsid;
while(1) {
    sleep(5);
    my $cmd = $plexWatch_script;
    $cmd .= ' ' . join(' ',@ARGV) if @ARGV;
    system($cmd);
}

sub CheckLock {
    open($script_fh, '<', $0)
        or die("Unable to open script source: $!\n");
    while (!flock($script_fh, LOCK_EX|LOCK_NB)) {
        print "$0 is already running. waiting.\n" if $debug;
        exit;
    }
}
