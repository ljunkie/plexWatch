#!/usr/bin/perl -w

##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified: 2013-07-18 14:00 PST
#
#  Version: 0.0.14
# https://github.com/ljunkie/plexWatch
##########################################

use strict;
use LWP::UserAgent;
use WWW::Curl::Easy; ## might change this back to LWP
use XML::Simple;
use DBI;
use Time::Duration;
use Getopt::Long;
use Pod::Usage;
use Fcntl qw(:flock);
use Time::ParseDate;
use POSIX qw(strftime);

## load config file
use File::Basename;
my $dirname = dirname(__FILE__);
if (!-e $dirname .'/config.pl') {
    print "\n** missing file $dirname/config.pl. Did you move edit config.pl-dist and copy to config.pl?\n\n";
    exit;
}
do $dirname.'/config.pl';
use vars qw/$data_dir $server $port $notify_started $notify_stopped $appname $user_display $alert_format $notify/; 
if (!$data_dir || !$server || !$port || !$appname || !$alert_format || !$notify) {
    print "config file missing data\n";
    exit;
}
## end

########################################## END CONFIG #######################################################

## used for later..
my $format_options = {
    'user' => 'user',
    'orig_user' => 'orig_user',
    'title' => 'title',
    'start_start' => 'start_time',
    'stop_time' => 'stop_time',
    'rating' => 'rating of video - TV-MA, R, PG-13, etc',
    'year' => 'year of video',
    'platform' => 'client platform ',
    'summary' => 'summary or video',
    'duration' => 'duration watched',
    'length' => 'length of video',
    'progress' => 'progress of video [only available on --watching]',
    'time_left' => 'progress of video [only available on --watching]',
};

if (!-d $data_dir) {
    print "\n** Sorry. Please create your datadir $data_dir\n\n";
    exit;
}

&CheckLock();


# Grab our options.
my %options = ();
GetOptions(\%options, 
           'watched',
           'nogrouping',
           'stats',
           'user:s',
           'watching',
	   'notify',
           'debug',
           'start:s',
           'stop:s',
           'format_start:s',
           'format_stop:s',
           'format_watched:s',
           'format_watching:s',
           'format_options',
	   'test_notify:s',
	   'show_xml',
           'help|?'
    ) or pod2usage(2);
pod2usage(-verbose => 2) if (exists($options{'help'}));


my $debug = $options{'debug'};
my $debug_xml = $options{'show_xml'};
if ($options{debug}) {
    use Data::Dumper;
}

my $date = localtime;
my $dbh = &initDB();    ## Initialize sqlite db

if ($options{'format_options'}) {
    print "\nFormat Options for alerts\n";
    print "\n\t    --start='" . $alert_format->{'start'} ."'";
    print "\n\t     --stop='" . $alert_format->{'stop'} ."'";
    print "\n\t  --watched='" . $alert_format->{'watched'} ."'";
    print "\n\t --watching='" . $alert_format->{'watching'} ."'";
    print "\n\n";
    
    foreach my $k (keys %{$format_options}) {
	printf("%15s %s\n", "{$k}", $format_options->{$k});
    }
    print "\n";
    exit;
}

## reset format if specified
$alert_format->{'start'} = $options{'format_start'} if $options{'format_start'};
$alert_format->{'stop'} = $options{'format_stop'} if $options{'format_stop'};
$alert_format->{'watched'} = $options{'format_watched'} if $options{'format_watched'};
$alert_format->{'watching'} = $options{'format_watching'} if $options{'format_watching'};


## show what the notify alerts will look like
if  ($options{test_notify}) {
    &RunTestNotify();
    exit;
}

########################################## START MAIN #######################################################


## display the output is limited by user (display user)
if ( ($options{'watched'} || $options{'watching'} || $options{'stats'}) && $options{'user'}) {
    my $extra = '';
    $extra = $user_display->{$options{'user'}} if $user_display->{$options{'user'}};
    foreach my $u (keys %{$user_display}) {
	$extra = $u if $user_display->{$u} =~ /$options{'user'}/i;
    }
    $extra = '[' . $extra .']' if $extra;
    printf("\n* Limiting results to %s %s\n", $options{'user'}, $extra);
}

####################################################################
## print all watched content
if ($options{'watched'} || $options{'stats'}) {
    
    my $stop = time();
    my ($start,$limit_start,$limit_end);
    
    if ($options{start}) {
	my $v = $options{start};
	my $now = time();
	$now = parsedate('today at midnight', FUZZY=>1) 	if ($v !~ /now/i);
	if ($start = parsedate($v, FUZZY=>1, NOW => $now)) {	    $limit_start = localtime($start);	}
    }
    
    if ($options{stop}) {
	my $v = $options{stop};
	my $now = time();
	$now = parsedate('today at midnight', FUZZY=>1) if ($v !~ /now/i);
	if ($stop = parsedate($v, FUZZY=>1, NOW => $now)) {	    $limit_end = localtime($stop);	}
    }
    
    my $is_watched = &GetWatched($start,$stop);
    
    ## already watched.
    if ($options{'watched'}) {
	printf ("\n======================================== %s ========================================\n",'Watched');
    }
    print "\nDate Range: ";
    if ($limit_start) {	print $limit_start;    } 
    else {	print "Anytime";    }
    print ' through ';
    
    if ($limit_end) {	print $limit_end;    } 
    else {	print "Now";    }
    
    my %seen = ();
    my %seen_user = ();
    my %stats = ();
    my $ntype = 'watched';
    if (keys %{$is_watched}) {
	print "\n";
	foreach my $k (sort {$is_watched->{$a}->{user} cmp $is_watched->{$b}->{'user'} || 
				 $is_watched->{$a}->{time} cmp $is_watched->{$b}->{'time'} } (keys %{$is_watched}) ) {
	    ## clean this up at some point -- skip user if user and/or display user is not = to specified 
	    my $skip =1;
	    if ($options{'user'}) {
	    	$skip = 0 if $options{'user'} &&  $options{'user'} =~ /$is_watched->{$k}->{user}/i; ## allow real user
		$skip = 0 if $options{'user'} && $user_display->{$is_watched->{$k}->{user}} &&  $options{'user'} =~ /$user_display->{$is_watched->{$k}->{user}}/i; ## allow display_user
	    }  else {	$skip = 0;    }
	    next if $skip;
	    
	    ## only show one watched status on movie/show per day (default) -- duration will be calculated from start/stop on each watch/resume
	    ## --nogrouping will display movie as many times as it has been started on the same day.
	    
	    ## to cleanup - maybe subroutine
	    my ($sec, $min, $hour, $day,$month,$year) = (localtime($is_watched->{$k}->{time}))[0,1,2,3,4,5]; 
	    $year += 1900;
	    $month += 1;
	    my $serial = parsedate("$year-$month-$day 00:00:00");
	    my $skey = $is_watched->{$k}->{user}.$year.$month.$day.$is_watched->{$k}->{title};
	    
	    ## get previous day -- see if video same title was watched then -- if so -- group them together for display purposes. stats and --nogrouping will still show the break
	    my ($sec2, $min2, $hour2, $day2,$month2,$year2) = (localtime($is_watched->{$k}->{time}-86400))[0,1,2,3,4,5]; 
	    $year2 += 1900;
	    $month2 += 1;
	    my $skey2 = $is_watched->{$k}->{user}.$year2.$month2.$day2.$is_watched->{$k}->{title};
	    if ($seen{$skey2}) {		$skey = $skey2;	    }
	    
	    ## use display name 
	    my $user = &FriendlyName($is_watched->{$k}->{user});
	    
	    ## stat -- quick and dirty -- to clean up later
	    $stats{$user}->{'total_duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    $stats{$user}->{'duration'}->{$serial} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    ## end
	    
	    next if !$options{'watched'};
	    if ($options{'nogrouping'}) {
		if (!$seen_user{$user}) {
		    $seen_user{$user} = 1;
		    print "\nUser: " . $user . "\n";
		}
		my $time = localtime ($is_watched->{$k}->{time} );
		my $info = &info_from_xml($is_watched->{$k}->{'xml'},$ntype,$is_watched->{$k}->{'time'},$is_watched->{$k}->{'stopped'});
		my $alert = &Notify($info,1);
		printf(" %s: %s\n",$time, $alert);
	    } else {
		if (!$seen{$skey}) {
		    $seen{$skey}->{'time'} = $is_watched->{$k}->{time};
		    $seen{$skey}->{'xml'} = $is_watched->{$k}->{xml};
		    $seen{$skey}->{'user'} = $user;
		    $seen{$skey}->{'stopped'} = $is_watched->{$k}->{stopped};
		    $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
		} else {
		    ## if same user/same movie/same day -- append duration -- must of been resumed
		    $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
		    if ($is_watched->{$k}->{stopped} > $seen{$skey}->{'stopped'}) {
			$seen{$skey}->{'stopped'} = $is_watched->{$k}->{stopped}; ## include max stopped in case someone wants to display it
		    }
		}
	    }
	}
    } else {	    print "\n\n* nothing watched\n";	}
    
    ## Grouping Watched TITLE by day - default
    if (!$options{'nogrouping'}) {
	foreach my $k (sort { 
	    $seen{$a}->{user} cmp $seen{$b}->{'user'} ||
		$seen{$a}->{time} cmp $seen{$b}->{'time'} 
		       } (keys %seen) ) {
	    if (!$seen_user{$seen{$k}->{user}}) {
		$seen_user{$seen{$k}->{user}} = 1;
		print "\nUser: " . $seen{$k}->{user} . "\n";
	    }
	    my $time = localtime ($seen{$k}->{time} );
	    my $info = &info_from_xml($seen{$k}->{xml},$ntype,$seen{$k}->{'time'},$seen{$k}->{'stopped'},$seen{$k}->{'duration'});
	    my $alert = &Notify($info,1);
	    printf(" %s: %s\n",$time, $alert);
	}
    }
    print "\n";

    ## show stats if --stats
    if ($options{stats}) {
	printf ("\n======================================== %s ========================================\n",'Stats');
	foreach my $user (keys %stats) {
	    printf ("user: %s's total duration %s \n", $user, duration_exact($stats{$user}->{total_duration}));
	    foreach my $epoch (sort keys %{$stats{$user}->{duration}}) {
		my $h_date = strftime "%a %b %e %Y", localtime($epoch);
		printf (" %s: %s %s\n", $h_date, $user, duration_exact($stats{$user}->{duration}->{$epoch}));
	    }
	    print "\n";
	}
    }
}


#####################################################
## print content being watched
if ($options{'watching'}) {
    my $in_progress = &GetInProgress();
    my $live = &GetSessions();    ## query API for current streams

    printf ("\n======================================= %s ========================================",'Watching');
    
    my %seen = ();
    if (keys %{$in_progress}) {
	print "\n";
	foreach my $k (sort { $in_progress->{$a}->{user} cmp $in_progress->{$b}->{'user'} || $in_progress->{$a}->{time} cmp $in_progress->{$b}->{'time'} } (keys %{$in_progress}) ) {
	    ## clean this up at some point -- skip user if user and/or display user is not = to specified 
	    my $skip =1;
	    if ($options{'user'}) {
	    	$skip = 0 if $options{'user'} &&  $options{'user'} =~ /$in_progress->{$k}->{user}/i; ## allow real user
		$skip = 0 if $options{'user'} && $user_display->{$in_progress->{$k}->{user}} &&  $options{'user'} =~ /$user_display->{$in_progress->{$k}->{user}}/i; ## allow display_user
	    }  else {	$skip = 0;    }
	    next if $skip;
	    my $live_key = (split("_",$k))[0];
	    
	    ## use display name 
	    my $user = $in_progress->{$k}->{user};
	    
	    $user = $user_display->{$user} if $user_display->{$user};
	    
	    if (!$seen{$user}) {
		$seen{$user} = 1;
		print "\nUser: " . $user . "\n";
	    }
	    
	    my $time = localtime ($in_progress->{$k}->{time} );
	    my $info = &info_from_xml($in_progress->{$k}->{'xml'},'watching',$in_progress->{$k}->{time});
	    
	    $info->{'progress'} = &durationrr($live->{$live_key}->{viewOffset}/1000);
	    $info->{'time_left'} = &durationrr(($info->{raw_length}/1000)-($live->{$live_key}->{viewOffset}/1000));
	    
	    my $alert = &Notify($info,1);
	    printf(" %s: %s\n",$time, $alert);
	}
	
    } else {	    print "\n * nothing in progress\n";	}
    print " \n";
}

if (%options && !$options{'notify'}) {
    if ($debug || $debug_xml) {
	print "\n* Skipping any Notifictions -- command line options set, use '--notify' or supply no options to enable notifications\n";
    }
    exit;
}

#################################################################
## Notify -notify || no options = notify on watch/stopped streams
if (!%options || $options{'notify'}) {
    my $vid = &GetSessions();    ## query API for current streams
    my $started= &GetStarted(); ## query streams already started/not stopped
    my $playing = ();            ## container of now playing id's - used for stopped status/notification
    
    
    ###########################################################################
    ## nothing being watched.. verify all notification went out
    ## this shouldn't happen ( only happened during development when I was testing -- but just in case )
    #### to fix
    if (!ref($vid)) {
	my $un = &GetUnNotified();
	foreach my $k (keys %{$un}) {
	    if (!$playing->{$k}) {
		my $ntype = 'start';
		my $start_epoch = $un->{$k}->{time} if $un->{$k}->{time};
		my $stop_epoch = '';
		my $info = &info_from_xml($un->{$k}->{'xml'},'start',$start_epoch,$stop_epoch);
		&Notify($info);
		&SetNotified($un->{$k}->{id});
		## another notification will go out about being stopped..
		## next run it will be marked as watched and notified
	    }
	}
    }
    ## end unnotified
    

    ## Quick hack to notify stopped content before start -- get a list of playing content
    foreach my $k (keys %{$vid}) {
	my $user = (split('\@',$vid->{$k}->{User}->{title}))[0];
	if (!$user) {	$user = 'Local';    }
	my $db_key = $k . '_' . $vid->{$k}->{key} . '_' . $user;
	$playing->{$db_key} = 1;
    }
    
    ## Notify on any Stop
    ## Iterate through all non-stopped content and notify if not playing
    if (ref($started)) {
	foreach my $k (keys %{$started}) {
	    if (!$playing->{$k}) {
		my $start_epoch = $started->{$k}->{time} if $started->{$k}->{time};
		my $stop_epoch = time();
		my $info = &info_from_xml($started->{$k}->{'xml'},'stop',$start_epoch,$stop_epoch);
		&Notify($info);
		&SetStopped($started->{$k}->{id},$stop_epoch);
	    }
	}
    }
    
    ## Notify on start/now playing
    foreach my $k (keys %{$vid}) {
	
	my $start_epoch = time();
	my $stop_epoch = ''; ## not stopped yet
	my $info = &info_from_xml(XMLout($vid->{$k}),'start',$start_epoch,$stop_epoch);
	
	## for insert 
	my $db_key = $k . '_' . $vid->{$k}->{key} . '_' . $info->{orig_user};
	
	## these shouldn't be neede any more - to clean up as we now use XML data from DB
	$info->{'orig_title'} = $vid->{$k}->{title};
	$info->{'orig_title_ep'} = '';
	$info->{'episode'} = '';
	$info->{'season'} = '';
	$info->{'genre'} = '';
	if ($vid->{$k}->{grandparentTitle}) {
	    $info->{'orig_title'} = $vid->{$k}->{grandparentTitle};
	    $info->{'orig_title_ep'} = $vid->{$k}->{title};
	    $info->{'episode'} = $vid->{$k}->{index};
	    $info->{'season'} = $vid->{$k}->{parentIndex};
	    if ($info->{'episode'} < 10) { $info->{'episode'} = 0 . $info->{'episode'};}
	    if ($info->{'season'} < 10) { $info->{'season'} = 0 . $info->{'season'}; }
	}
	## end unused data to clean up
	
	## ignore content that has already been notified
	if ($started->{$db_key}) {
	    if ($debug) { 
		## set notifcation again - start day will be off for now.
		&Notify($info);
		print &consoletxt("Already Notified") . "\n"; 
	    };
	} 
	## unnotified - insert into DB and notify
	else {
	    my $insert_id = &ProcessStart($vid->{$k},$db_key,$info->{'title'},$info->{'platform'},$info->{'orig_user'},$info->{'orig_title'},$info->{'orig_title_ep'},$info->{'genre'},$info->{'episode'},$info->{'season'},$info->{'summary'},$info->{'rating'},$info->{'year'});
	    &Notify($info);
	    &SetNotified($insert_id);
	}
    }
}

#############################################################################################################################

sub formatAlert() {
    my $info = shift;
    my %alert = %{$info};
    my $type = $alert{'ntype'};
    my $format = $alert_format->{'start'};
    ## to fix at some point -- allow users to custome event/collapse/etc... just more logic to work on later.
    my $orig_start = '{user} watching {title} on {platform}'; # used for prowl 'EVENT' (if collapse is enabled)
    my $orig_stop = '{user} watched {title} on {platform} for {duration}'; # used for prowl 'EVENT' (if collapse is enabled)
    my $orig_watched = $orig_stop; # not really needed.. just keeping standards
    my $orig_watching = $orig_start; # not really needed.. just keeping standards
    my $orig = $orig_start;
    if ($type =~ /stop/i) {
	$format = $alert_format->{'stop'};
	$orig = $orig_stop;
    } elsif ($type =~ /watched/i) {
	$format = $alert_format->{'watched'};
	$orig = $orig_watched;
    } elsif ($type =~ /watching/i) {
	$format = $alert_format->{'watching'};
	$orig = $orig_watching;
    }
    if ($debug) { print "format: $format\n";}
    my $s = $format;
    my $regex = join "|", keys %alert;
    $regex = qr/$regex/;
    $s =~ s/{($regex)}/$alert{$1}/g;
    $orig =~ s/{($regex)}/$alert{$1}/g;
    return ($s,$orig);
}

sub Notify() {
    my $info = shift;
    my $ret_alert = shift;
    my $type = $info->{'ntype'};
    my ($alert,$orig) = &formatAlert($info);
    my $extra = ''; ## clean me
    
    ## only return the alert - do not notify -- used for CLI to keep formatting the same
    return &consoletxt($alert) if $ret_alert;
    
    if ($notify_started && $type =~ /start/ ||	$notify_stopped && $type =~ /stop/) {
	if ($notify->{'prowl'}->{'enabled'})    {     &NotifyProwl($alert,$type,$orig);	}
	if ($notify->{'pushover'}->{'enabled'}) {     &NotifyPushOver($alert); }
	if ($notify->{'growl'}->{'enabled'})    {     &NotifyGrowl($alert); }
    }
    
    my $console = &consoletxt("$date: $alert $extra"); 
    
    if ($debug || $options{test_notify}) {	print $console ."\n";    }
    
    ## file logging
    if ($notify->{'file'}->{'enabled'}) {	
	open FILE, ">>", $notify->{'file'}->{'filename'}  or die $!;
	print FILE "$console\n";
	close(FILE);
    }
    
}

sub ProcessStart() {
    my ($xmlref,$db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year) = @_;
    my $xml =  XMLout($xmlref);
    
    my $sth = $dbh->prepare("insert into processed (session_id,title,platform,user,orig_title,orig_title_ep,genre,episode,season,summary,rating,year,xml) values (?,?,?,?,?,?,?,?,?,?,?,?,?)");
    $sth->execute($db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year,$xml) or die("Unable to execute query: $dbh->errstr\n");
    
    return  $dbh->sqlite_last_insert_rowid();
}

sub GetSessions() {
    my $url = "http://$server:$port/status/sessions";
    my $ret = '';
    sub chunk { my ($data,$pointer)=@_; ${$pointer}.=$data; return length($data) }
    my $curl = WWW::Curl::Easy->new();
    my $res = $curl->setopt(CURLOPT_URL, $url);
    $res = $curl->setopt(CURLOPT_VERBOSE, 0);
    $res = $curl->setopt(CURLOPT_NOPROGRESS, 1);
    $res = $curl->setopt(CURLOPT_WRITEFUNCTION, \&chunk );
    $res = $curl->setopt(CURLOPT_FILE, \$ret );
    $res = $curl->perform();
    my $msg = $curl->errbuf; # report any error message                           
    my $XML = $ret;
    if ($debug_xml) {
	print "URL: $url\n";
	print "===================================XML CUT=================================================\n";
	print $XML;
	print "===================================XML END=================================================\n";
    }
    my $data = XMLin($XML,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
    return $data->{'Video'};
}

sub CheckNotified() {
    my $db_key = shift;
    if ($db_key) {
	my $cmd = "select id from processed where notified = 1 and session_id = '$db_key'";
	my $sth = $dbh->prepare($cmd);
	$sth->execute or die("Unable to execute query: $dbh->errstr\n");
	my @row = $sth->fetchrow_array;
	return $row[0];
    }
}

sub GetUnNotified() {
    my $info = ();
    my $cmd = "select * from processed where notified != 1 or notified is null";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
	$info->{$row_hash->{'session_id'}} = $row_hash;
    }
    return $info;
}


sub GetTestNotify() {
    my $option = shift;
    my $info = ();
    my $cmd = "select * from processed order by time desc limit 1";
    if ($option !~ /start/i) {
        $cmd = "select * from processed where stopped is not null order by time desc limit 1";
    }
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
	$info->{$row_hash->{'session_id'}} = $row_hash;
    }
    return $info;
}

sub GetStarted() {
    my $info = ();
    my $cmd = "select * from processed where notified = 1 and stopped is null";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
	$info->{$row_hash->{'session_id'}} = $row_hash;
    }
    return $info;
}


sub GetWatched() {
    my $info = ();
    my ($start,$stop) = @_;
    my $where;
    $where .= " and time >= $start "     if $start;
    $where .= " and time <= $stop " if $stop;
    ## going forward only include rows with xml -- mainly for my purposes as I didn't relase this to public before I included xml
    my $cmd = "select * from processed where notified = 1 and stopped is not null and xml is not null";
    $cmd .= $where if $where;
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
	$info->{$row_hash->{'session_id'}} = $row_hash;
    }
    return $info;
}

sub GetInProgress() {
    my $info = ();
    my $cmd = "select * from processed where notified = 1 and stopped is null";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
	$info->{$row_hash->{'session_id'}} = $row_hash;
    }
    return $info;
}

sub SetNotified() {
    my $id = shift;
    if ($id) {
	my $cmd = "update processed set notified = 1 where id = '$id'";
	my $sth = $dbh->prepare($cmd);
	$sth->execute or die("Unable to execute query: $dbh->errstr\n");
    }
}



sub SetStopped() {
    my $db_key = shift;
    my $time = shift;
    if ($db_key) {
	$time = time() if !$time;
	my $sth = $dbh->prepare("update processed set stopped = ? where id = ?");
	$sth->execute($time,$db_key) or die("Unable to execute query: $dbh->errstr\n");
    }
}

sub initDB() {
    ## inital columns - id, session_id, time 
    
    my $dbtable = 'processed';
    my $dbh = DBI->connect("dbi:SQLite:dbname=$data_dir/plexWatch.db","","");
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    #ALTER TABLE Name ADD COLUMN new_column INTEGER DEFAULT 0
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) { }
    else {
        my $cmd = "CREATE TABLE $dbtable (id INTEGER PRIMARY KEY, session_id text, time timestamp default (strftime('%s', 'now')) );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
    }
    
    ## Add new columns/indexes on the fly  -- and change definitions
    my @dbcol = (
	{ 'name' => 'user', 'definition' => 'text', }, 
	{ 'name' => 'platform', 'definition' => 'text', }, 
	{ 'name' => 'title', 'definition' => 'text', }, 
	{ 'name' => 'orig_title', 'definition' => 'text', },
	{ 'name' => 'orig_title_ep', 'definition' => 'text', },
	{ 'name' => 'episode', 'definition' => 'integer', },
	{ 'name' => 'season', 'definition' => 'integer', },
	{ 'name' => 'year', 'definition' => 'text', },
	{ 'name' => 'rating', 'definition' => 'text', },
	{ 'name' => 'genre', 'definition' => 'text', },
	{ 'name' => 'summary', 'definition' => 'text', },
	{ 'name' => 'notified', 'definition' => 'INTEGER', },
	{ 'name' => 'stopped', 'definition' => 'timestamp',},
	{ 'name' => 'xml', 'definition' => 'text',},
	);
    
    my @dbidx = (
	{ 'name' => 'userIdx', 'table' => 'user', },
	{ 'name' => 'timeIdx', 'table' => 'time', },
	{ 'name' => 'stoppedIdx', 'table' => 'stopped', },
	{ 'name' => 'notifiedIdx', 'table' => 'notified', },
	); 
    
    &initDBtable($dbh,$dbtable,\@dbcol);
    
    
    ## check definitions
    my %dbcol_exists = ();
    
    for ( @{ $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)") } ) { 
	$dbcol_exists{$_->[1]} = $_->[2]; 
    };
    
    ## alter table defintions if needed
    my $alter_def = 0;
    for my $col ( @dbcol ) {
	if ($dbcol_exists{$col->{'name'}} && $dbcol_exists{$col->{'name'}} ne $col->{'definition'}) {	    $alter_def =1;	}
    }
    
    if ($alter_def) {
	print "New Table definitions.. upgrading DB\n";
	$dbh->begin_work;
	
	eval {
	    local $dbh->{RaiseError} = 1;
	    my $tmp_table = 'tmp_update_table';
	    &initDBtable($dbh,$tmp_table,\@dbcol); ## create DB table with new sturction
	    $dbh->do("INSERT INTO $tmp_table SELECT * FROM $dbtable");
	    $dbh->do("DROP TABLE $dbtable");
	    $dbh->do("ALTER TABLE $tmp_table RENAME TO $dbtable");
	    $dbh->commit; 
	};
	if ($@) {
	    print "Could not upgrade table defintions - Transaction aborted because $@\n";
	    eval { $dbh->rollback };
	}
	print "DB update DONE\n";
    }
    
    
    ## now verify indexes
    
    my %dbidx_exists = ();
    for ( @{ $dbh->selectall_arrayref( "PRAGMA INDEX_LIST($dbtable)") } ) { 
	$dbidx_exists{$_->[1]} = 1; };
    for my $idx ( @dbidx ) {
	if ($debug) { print "CREATE INDEX $idx->{'name'} ON $dbtable ($idx->{'table'})\n" unless ( $dbidx_exists{$idx->{'name'}} ); }
	$dbh->do("CREATE INDEX $idx->{'name'} ON $dbtable ($idx->{'table'})")
	    unless ( $dbidx_exists{$idx->{'name'}} );
    }
    
    return $dbh;
}

sub initDBtable() {
    my $dbh = shift;
    my $dbtable = shift;
    my $col = shift;
    my @dbcol = @$col;
    
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) {    }
    else {
        my $cmd = "CREATE TABLE $dbtable (id INTEGER PRIMARY KEY, session_id text, time timestamp default (strftime('%s', 'now')) );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
    }
    
    my %dbcol_exists = ();
    for ( @{ $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)") } ) { 	$dbcol_exists{$_->[1]} = $_->[2];     };
    
    for my $col ( @dbcol ) {
	if (!$dbcol_exists{$col->{'name'}}) {
	    if ($debug) { print "ALTER TABLE $dbtable ADD COLUMN $col->{'name'} $col->{'definition'}\n";}
	    $dbh->do("ALTER TABLE $dbtable ADD COLUMN $col->{'name'} $col->{'definition'}");
	}
    }
    ## update any old colums that just had 1 set for stopped -- no need for this
    #$dbh->do("update processed set stopped = time where stopped = 1");

}

sub NotifyProwl() {
    ## modified from: https://www.prowlapp.com/static/prowl.pl
    my %prowl = %{$notify->{prowl}};
    
    $prowl{'event'} = '';
    $prowl{'notification'} = shift;    
    if ($prowl{'collapse'}) {
	my $type = shift;
	my $orig = shift;
	#my @p = split(':',shift);
	#$prowl{'application'} .= ' - ' . shift(@p);
	$prowl{'event'} = $orig;
    }


    
    $prowl{'priority'} ||= 0;
    $prowl{'application'} ||= $appname;
    $prowl{'url'} ||= "";
    
    # URL encode our arguments
    $prowl{'application'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'event'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'notification'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    
    # allow line breaks in message/notification
    $prowl{'notification'} =~ s/\%5Cn/\%0d\%0a/g;
    
    my $providerKeyString = '';
    
    # Generate our HTTP request.
    my ($userAgent, $request, $response, $requestURL);
    $userAgent = LWP::UserAgent->new;
    $userAgent->agent("ProwlScript/1.2");
    $userAgent->env_proxy();
    
    $requestURL = sprintf("https://prowlapp.com/publicapi/add?apikey=%s&application=%s&event=%s&description=%s&priority=%d&url=%s%s",
			  $prowl{'apikey'},
			  $prowl{'application'},
			  $prowl{'event'},
			  $prowl{'notification'},
			  $prowl{'priority'},
			  $prowl{'url'},
			  $providerKeyString);
    
    $request = HTTP::Request->new(GET => $requestURL);
    $response = $userAgent->request($request);
    
    if ($response->is_success) {
	if ($debug) { print "PROWL - Notification successfully posted.\n";}
    } elsif ($response->code == 401) {
	print STDERR "PROWL - Notification not posted: incorrect API key.\n";
    } else {
	print STDERR "PROWL - Notification not posted: " . $response->content . "\n";
    }
}

sub NotifyPushOver() {
    my %po = %{$notify->{pushover}};    
    my $ua      = LWP::UserAgent->new();
    $po{'message'} = shift;
    #my $extra  = shift; ## i need to test pushover myself before I can see what this looks like
    
    my $response = $ua->post( "https://api.pushover.net/1/messages.json", [
				  "token" => $po{'token'},
				  "user" => $po{'user'},
				  "sound" => $po{'sound'},
				  "title" => $po{'title'},
				  "message" => $po{'message'},
			      ]);
    my $content  = $response->decoded_content();
    if ($content !~ /\"status\":1/) {
	print "Failed to post PushOver notification -- $content\n";
    } else {
	if ($debug) { print "PushOver - Notification successfully posted. $content\n";}
    }
}

sub NotifyGrowl() { 
    my $alert = shift;
    my %growl = %{$notify->{growl}};    
    if (!-f  $growl{'script'} ) {
	print STDERR "\nFailed to send GROWL notification -- $growl{'script'} does not exists\n";
    } else {
	system( $growl{'script'}, "-n", $growl{'appname'}, "--image", $growl{'icon'}, "-m", $alert); 
    }
}

sub consoletxt() {
    ## remove line breaks and none ascii
    my $console = shift;
    $console =~ s/\n\n/\n/g;
    $console =~ s/\n/,/g;
    $console =~ s/,$//; # get rid of last comma
    $console =~ s/[^[:ascii:]]+//g; 
    return $console;
}

sub getDuration() {
    my ($start,$stop) = @_;
    my $diff = $stop-$start;
    
    #$diff = 0 if $diff < 0;  ## dirty.
    if ($diff > 0) {
	return &durationrr($diff);
    } else {
	return 'unknown';
    }
}

sub CheckLock {
    open(my $script_fh, '<', $0)
	or die("Unable to open script source: $!\n");
    my $max_wait = 60; ## wait 60 seconds before exiting..
    my $count = 0;
    while (!flock($script_fh, LOCK_EX|LOCK_NB)) {
	#unless (flock($script_fh, LOCK_EX|LOCK_NB)) {
	#print "$0 is already running. Exiting.\n";
	$count++;
	sleep 1;
	if ($count > $max_wait) { 
	    print "CRITICAL: max wait of $max_wait seconds reached.. other running $0?\n";
	    exit(2);
	}
    }
}

sub FriendlyName() {
    my $user = shift;
    $user = $user_display->{$user} if $user_display->{$user};
    return $user;
}

sub durationrr() {
    my $sec = shift;
    if ($sec < 3600) { 
	return duration($sec,1);
    }
    return duration($sec,2);
}

sub info_from_xml() {
    my $hash = shift;
    my $ntype = shift;
    my $start_epoch = shift;
    my $stop_epoch = shift;
    my $duration = shift; ## special case to group start/stops
    ## start time is in xml
    
    my $vid = XMLin($hash,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
    
    
    my $start_time = '';
    my $stop_time = '';
    my $time = $start_epoch;
    $start_time = localtime($start_epoch)  if $start_epoch;
    $stop_time = localtime($stop_epoch)  if $stop_epoch;
    
    if (!$duration) {
	if ($time && $stop_epoch) {
	    $duration = $stop_epoch-$time;
	    $duration = &durationrr($duration);
	}    
    } else {
	$duration = &durationrr($duration);
    }
    my ($rating,$year,$summary,$extra_title,$genre,$platform,$title,$episode,$season);    
    $rating = $year = $summary = $extra_title = $genre = $platform = $title = $episode = $season = '';
    
    $title = $vid->{title};
    ## prefer title over platform if exists ( seem to have the exact same info of platform with useful extras )
    if ($vid->{Player}->{title}) {	$platform =  $vid->{Player}->{title};    }
    elsif ($vid->{Player}->{platform}) {	$platform = $vid->{Player}->{platform};    }

    
    my $length;
    ## not sure which one is more valid.. {'TranscodeSession'}->{duration} or ->{duration}
    if (!$vid->{duration}) {
	$length = sprintf("%02d",$vid->{'TranscodeSession'}->{duration}/1000) if $vid->{'TranscodeSession'}->{duration};
    } else {
	$length = sprintf("%02d",$vid->{duration}/1000) if $vid->{duration};
    }
    $length = &durationrr($length);
    
    my $orig_user = (split('\@',$vid->{User}->{title}))[0];
    if (!$orig_user) {	$orig_user = 'Local';    }
    
    
    $year = $vid->{year} if $vid->{year};
    $rating .= $vid->{contentRating} if ($vid->{contentRating});
    $summary = $vid->{summary} if $vid->{summary};
    
    my $orig_title = $title;
    my $orig_title_ep = '';
    ## user can modify format, but for now I am keeping 'show title - episode title - s##e##' as the default title
    if ($vid->{grandparentTitle}) {
	$orig_title = $vid->{grandparentTitle};
	$orig_title_ep = $title;
	
	$title = $vid->{grandparentTitle} . ' - ' . $title;
	$episode = $vid->{index};
	$season = $vid->{parentIndex};
	if ($episode < 10) { $episode = 0 . $episode};
	if ($season < 10) { $season = 0 . $season};
	$title .= ' - s'.$season.'e'.$episode;
    }
    
    ## formatting now allows user to include year, rating, etc...
    #if ($vid->{'type'} =~ /movie/) {
    #	## to fix.. multiple genres
    #	#if (defined($vid->{Genre})) {	    $title .= ' ['.$vid->{Genre}->{tag}.']';	}
    #	$title .= ' ['.$year.']';
    #	$title .= ' ['.$rating.']';
    #   }
    
    my $user = &FriendlyName($orig_user);
    
    ## ADD keys here when needed for &Notify hash
    my $info = {
	'user' => $user,
	'orig_user' => $orig_user,
	'title' =>  $title,
	'platform' => $platform,
	'time' => $time,
	'stop_time' => $stop_time,
	'start_time' => $start_time,
	'rating' => $rating, 
	'year' => $year, 
	'platform' => $platform, 
	'summary' => $summary,
	'duration' => $duration,
	'length' => $length,
	'raw_length' =>  $vid->{duration},
	'ntype' => $ntype,
    };
    
    return $info;
}


sub RunTestNotify() {
    my $ntype = 'start'; ## default
    $ntype = 'stop' if $options{test_notify} =~ /stop/;
    $format_options->{'ntype'} = $ntype;
    my $info = &GetTestNotify($ntype);
    if ($info) {
	foreach my $k (keys %{$info}) {
	    my $start_epoch = $info->{$k}->{time} if $info->{$k}->{time}; ## DB only
	    my $stop_epoch = $info->{$k}->{stopped} if $info->{$k}->{stopped}; ## DB only
	    my $info = &info_from_xml($info->{$k}->{'xml'},$ntype,$start_epoch,$stop_epoch);
	    &Notify($info);
	}
    } else {
	&Notify($format_options);
    }
}




__DATA__

__END__

=head1 NAME 

plexWatch.pl - Notify and Log 'Now Playing' content from a Plex Media Server

=head1 SYNOPSIS


plexWatch.pl [options]

  Options:

   -notify=...        Notify any content watched and or stopped [this is default with NO options given]

   -watched=...       print watched content
        -start=...         limit watched status output to content started AFTER/ON said date/time
        -stop=...          limit watched status output to content started BEFORE/ON said date/time
        -nogrouping        will show same title multiple times if user has watched/resumed title on the same day
        -user=...          limit output to a specific user. Must be exact, case-insensitive

   -watching=...      print content being watched

   -stats             show total time watched / per day breakout included

   ############################################################################################3
 
   --format_options        : list all available formats for notifications and cli output

   --format_start=".."     : modify start notification :: --format_start='{user} watching {title} on {platform}'
 
   --format_stop=".."      : modify stop nottification :: --format_stop='{user} watched {title} on {platform} for {duration}'
 
   --format_watched=".."   : modify cli output for --watched  :: --format_watched='{user} watched {title} on {platform} for {duration}'

   --format_watching=".."  : modify cli output for --watching :: --format_watching='{user} watching {title} on {platform}'

   ############################################################################################3
   * Debug Options

   -test_notify=start        send a test notifcation for a start event. To test a stop event use -test_notify=stop 
   -show_xml                 show xml result from api query
   -debug                    hit and miss - not very useful

=head1 OPTIONS

=over 15

=item B<-notify>

This will send you a notification through prowl and/or pushover. It will also log the event to a file and to the database.
This is the default if no options are given.

=item B<-watched>

Print a list of watched content from all users.

=item B<-start>

* only works with -watched

limit watched status output to content started AFTER said date/time

Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

   -start=2013-06-29
   -start="2013-06-29 8:00pm"
   -start="today"
   -start="today at 8:30pm"
   -start="last week"
   -start=... give it a try and see what you can use :)

=item B<-stop>

* only works with -watched

limit watched status output to content started BEFORE said date/time

Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

   -stop=2013-06-29
   -stop="2013-06-29 8:00pm"
   -stop="today"
   -stop="today at 8:30pm"
   -stop="last week"
   -stop=... give it a try and see what you can use :)

=item B<-nogrouping>

* only works with -watched

will show same title multiple times if user has watched/resumed title on the same day


with --nogrouping
 Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 27 minutes and 54 seconds]
 Sun Jun 30 15:41:02 2013: exampleUser watched: Your Highness [2011] [R] [duration: 4 minutes and 59 seconds]
 Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 24 minutes and 17 seconds]
 Sun Jun 30 17:48:01 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 1 hour, 44 minutes, and 1 second]
 Sun Jun 30 19:45:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour and 24 minutes]

without --nogrouping [default]
 Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour, 56 minutes, and 53 seconds]
 Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 2 hours, 8 minutes, and 18 seconds]


=item B<-user>

* works with -watched and -watching

limit output to a specific user. Must be exact, case-insensitive

=item B<-watching>

Print a list of content currently being watched

=item B<-stats>

show total watched time and show total watched time per day

=item B<-show_xml>

Print the XML result from query to the PMS server in regards to what is being watched. Could be useful for troubleshooting..

=item B<-debug>

This can be used. I have not fully set everything for debugging.. so it's not very useful

=back

=head1 DESCRIPTION

This program will Notify and Log 'Now Playing' content from a Plex Media Server

=head1 HELP

nothing to see here.

=cut


