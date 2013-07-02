#!/usr/bin/perl -w

##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified: 2013-07-01 21:34 PST
#
#  Version: 0.0.11
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

my $data_dir = '/opt/plexWatch/'; ## to store the DB, logfile - can be the same as this script

my $server = 'localhost'; ## IP of PMS - or localhost
my $port = 32400;         ## port of PMS

my $notify_started = 1;   ## notify when a stream is started (first play)
my $notify_stopped = 1;   ## notify when a stream is stopped

my $appname = 'plexWatch';

## Give a user a more friendly name. I.E. REAL_USER will now be Frank
my $user_display = {'REAL_USER1' => 'Frank',
		    'REAL_USER2' => 'Carrie',
};

## Notification Options
my $notify = {

    'file' => {
	'enabled' => 1,  ## 0 or 1 - set to 1 to enable File Logging
	'filename' => "$data_dir/plexWatch.log", ## default is plexWatch.log
    },
    
   'prowl' => {
       'enabled' => 0, ## 0 or 1 - set to 1 to enable PROWL
       'apikey' => 'YOUR API KEY', ## your API key
       'application' => $appname,
       'priority' => 0,
       'url' => '',
    },
    
    ## not tested but should work - want to gift the app for me to test?? -->> rob at rarforge.com
    'pushover' => {
	'enabled' => 0, ## set to 1 to enable PushOver
	'token' => 'YOUR APP TOKEN', ## your app token
	'user' => 'YOUR USER TOKEN',  ## your user token
	'title' => $appname,
	'sound' => 'intermission',
    },

};

########################################## END CONFIG #######################################################

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

## display the output is limited by user (display user)
if ( ($options{'watched'} || $options{'watching'}) && $options{'user'}) {
    my $extra = '';
    $extra = $user_display->{$options{'user'}} if $user_display->{$options{'user'}};
    foreach my $u (keys %{$user_display}) {
	$extra = $u if $user_display->{$u} =~ /$options{'user'}/i;
    }
    $extra = '[' . $extra .']' if $extra;
    printf("\n* Limiting results to %s %s\n", $options{'user'}, $extra);
}


## print all watched content
if ($options{'watched'}) {

    my $start;
    my $stop = time();
    my $limit_start;
    my $limit_end;
    

    if ($options{start}) {
	my $v = $options{start};
	my $now = time();
	$now = parsedate('today at midnight', FUZZY=>1) 	if ($v !~ /now/i);
	
	if ($start = parsedate($v, FUZZY=>1, NOW => $now)) {
	    $limit_start = localtime($start);
	}
    }
    
    if ($options{stop}) {
	my $v = $options{stop};
	my $now = time();
	$now = parsedate('today at midnight', FUZZY=>1) if ($v !~ /now/i);
	if ($stop = parsedate($v, FUZZY=>1, NOW => $now)) {
	    $limit_end = localtime($stop);
	}
    }
    
    my $is_watched = &GetWatched($start,$stop);

    ## already watched.
    printf ("\n======================================== %s ========================================\n",'Watched');
    print "Date Range: ";
    if ($limit_start) {	print $limit_start;    } 
    else {	print "Anytime";    }
    print ' through ';

    if ($limit_end) {	print $limit_end;    } 
    else {	print "Now";    }

    my %seen = ();
    my %seen_user = ();
    my %stats = ();
    if (keys %{$is_watched}) {
	print "\n";

	foreach my $k (sort {$is_watched->{$a}->{user} cmp $is_watched->{$b}->{'user'} || $is_watched->{$a}->{time} cmp $is_watched->{$b}->{'time'} } (keys %{$is_watched}) ) {
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
	    ## end 
	    
	    my $skey = $is_watched->{$k}->{user}.$year.$month.$day.$is_watched->{$k}->{title};
	    
	    ## use display name 
	    my $user = $is_watched->{$k}->{user};
	    $user = $user_display->{$user} if $user_display->{$user};
	    
	    ## stat -- quick and dirty -- to clean up later
	    $stats{$user}->{'total_duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    $stats{$user}->{'duration'}->{$serial} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    ## end
	    
	    
	    my $extra_title;
	    if ($is_watched->{$k}->{season} && $is_watched->{$k}->{episode}) { 
		my $episode = $is_watched->{$k}->{episode}; 
		my $season = $is_watched->{$k}->{season};
		if ($episode < 10) { $episode = 0 . $episode};
		if ($season < 10) { $season = 0 . $season};
		$extra_title = ' - s'.$season.'e'.$episode;
	    }
	    
	    if ($options{'nogrouping'}) {
		if (!$seen_user{$user}) {
		    $seen_user{$user} = 1;
		    print "\nUser: " . $user . "\n";
		}
		## move to bottom
		my $time = localtime ($is_watched->{$k}->{time} );
		my $duration = &getDuration($is_watched->{$k}->{time},$is_watched->{$k}->{stopped});
		my $title = $is_watched->{$k}->{title};
		$title .= $seen{$skey}->{'title'} = $extra_title if $extra_title;
		my $alert = sprintf(' %s: %s watched: %s [duration: %s]', $time,$user, $title, $duration);
		print $alert . "\n";
	    } else {
		if (!$seen{$skey}) {
		    $seen{$skey}->{'time'} = $is_watched->{$k}->{time};
		    $seen{$skey}->{'user'} = $user;
		    $seen{$skey}->{'title'} = $is_watched->{$k}->{title};
		    $seen{$skey}->{'title'} .= $extra_title if $extra_title;
		    $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
		} else {
		    ## if same user/same movie/same day -- append duration -- must of been resumed
		    $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
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
	    my $duration = duration_exact($seen{$k}->{duration});
	    my $alert = sprintf(' %s: %s watched: %s [duration: %s]', $time,$seen{$k}->{user}, $seen{$k}->{title}, $duration);
	    print "$alert\n";
	}
    }
    print "\n";

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

## print content being watched
if ($options{'watching'}) {
    my $in_progress = &GetInProgress();
    
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
	    
	    ## use display name 
	    my $user = $in_progress->{$k}->{user};
	    
	    #print Dumper($in_progress);
	    $user = $user_display->{$user} if $user_display->{$user};
	    
	    if (!$seen{$user}) {
		$seen{$user} = 1;
		print "\nUser: " . $user . "\n";
	    }
	    
	    my $time = localtime ($in_progress->{$k}->{time} );
	    my $alert = sprintf(' %s: %s is watching: %s', $time,$user, $in_progress->{$k}->{title});
	    #my $extra = sprintf("rated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s",  $in_progress->{$k}->{rating}, $in_progress->{$k}->{year}, $in_progress->{$k}->{user}, $in_progress->{$k}->{platform}, $in_progress->{$k}->{summary});
	    print $alert . "\n";
	    #print $extra . "\n";
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


## Notify -notify || no options = notify on watch/stopped streams
if (!%options || $options{'notify'}) {
    my $vid = &GetSessions();    ## query API for current streams
    my $started= &GetStarted(); ## query streams already started/not stopped
    my $playing = ();            ## container of now playing id's - used for stopped status/notification
    
    ## nothing being watched.. verify all notification went out
    ## this shouldn't happen --- just to be sure.
    if (!ref($vid)) {
	my $info = &GetUnNotified();
	foreach my $k (keys %{$info}) {
	    if (!$playing->{$k}) {
		my $time = localtime ($info->{$k}->{time} );
		
		## use display name 
		my $user = $info->{$k}->{user};
		$user = $user_display->{$user} if $user_display->{$user};
		
		my $alert = sprintf('%s is watching: %s on %s', $user, $info->{$k}->{title}, $info->{$k}->{platform});
		my $extra = sprintf("Missed Notification\nStarted: %s\n\nrated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s", $time, $info->{$k}->{rating}, $info->{$k}->{year}, $user, $info->{$k}->{platform}, $info->{$k}->{summary});
		
		&Notify($alert,$extra,'start');
		&SetNotified($info->{$k}->{id});
		&SetStopped($info->{$k}->{id});
		## another notification will go out about being stopped..
	    }
	}
    }
    
    ## Quick hack to notify stopped content before start
    foreach my $k (keys %{$vid}) {
	my $user = (split('\@',$vid->{$k}->{User}->{title}))[0];
	if (!$user) {	$user = 'Local';    }
	my $db_key = $k . '_' . $vid->{$k}->{key} . '_' . $user;
	$playing->{$db_key} = 1;
    }
    
    ## Notify on any Stop
    if (ref($started)) {
	foreach my $k (keys %{$started}) {
	    if (!$playing->{$k}) {
		my $start_time = localtime($started->{$k}->{time});
		my $stop_epoch = time();
		
		## use display name 
		my $user = $started->{$k}->{user};
		$user = $user_display->{$user} if $user_display->{$user};
		
		my $duration = &getDuration($started->{$k}->{time},$stop_epoch);
		my $alert = sprintf('%s stopped watching: %s on %s', $user, $started->{$k}->{title}, $started->{$k}->{platform});
		my $extra = sprintf("\nDuration: %s\nplatform: %s\n started: %s", $duration,$started->{$k}->{platform}, $start_time);
		
		&Notify($alert,$extra,'stop');
		&SetStopped($started->{$k}->{id},$stop_epoch);
	    }
	}
    }
    
    ## Notify on start/now playing
    foreach my $k (keys %{$vid}) {
	my ($rating,$year,$summary,$extra_title,$genre,$platform,$title,$episode,$season);
	$rating = $year = $summary = $extra_title = $genre = $platform = $title = $episode = $season = '';
	
	$title = $vid->{$k}->{title};
	## prefer title over platform if exists ( seem to have the exact same info of platform with useful extras )
	if ($vid->{$k}->{Player}->{title}) {	$platform =  $vid->{$k}->{Player}->{title};    }
	elsif ($vid->{$k}->{Player}->{platform}) {	$platform = $vid->{$k}->{Player}->{platform};    }
	
	my $orig_user = (split('\@',$vid->{$k}->{User}->{title}))[0];
	if (!$orig_user) {	$orig_user = 'Local';    }
	
	## use display name 
	my $user = $orig_user;
	$user = $user_display->{$user} if $user_display->{$user};
	
	my $db_key = $k . '_' . $vid->{$k}->{key} . '_' . $orig_user;
	
	$year = $vid->{$k}->{year} if $vid->{$k}->{year};
	$rating .= $vid->{$k}->{contentRating} if ($vid->{$k}->{contentRating});
	$summary = $vid->{$k}->{summary} if $vid->{$k}->{summary};
	
	my $orig_title = $title;
	my $orig_title_ep = '';
	if ($vid->{$k}->{grandparentTitle}) {
	    $orig_title = $vid->{$k}->{grandparentTitle};
	    $orig_title_ep = $title;
	    
	    $title = $vid->{$k}->{grandparentTitle} . ' - ' . $title;
	    $episode = $vid->{$k}->{index};
	    $season = $vid->{$k}->{parentIndex};
	    if ($episode < 10) { $episode = 0 . $episode};
	    if ($season < 10) { $season = 0 . $season};
	    #$extra_title .= ' episode: s'.$season.'e'.$episode;
	    $title .= ' - s'.$season.'e'.$episode;
	}
	
	if ($vid->{$k}->{'type'} =~ /movie/) {
	    ## to fix.. multiple genres
	    #if (defined($vid->{$k}->{Genre})) {	    $title .= ' ['.$vid->{$k}->{Genre}->{tag}.']';	}
	    $title .= ' ['.$year.']';
	    $title .= ' ['.$rating.']';
	    #$summary = $vid->{$k}->{tagline};
	}
	
	my $alert = sprintf('%s is watching: %s on %s', $user, $title, $platform);
	#my $extra = sprintf("%s\n rated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s", $extra_title, $rating, $year, $user, $platform, $summary);
	my $extra = sprintf("rated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s", $rating, $year, $user, $platform, $summary);
	
	if ($started->{$db_key}) {
	    ##if (&CheckNotified($db_key)) { old -- we now have started container (streams already notified and not stopped)
	    if ($debug) { 
		my $insert_id = &ProcessStart($vid->{$k},$db_key,$title,$platform,$orig_user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year);
		print &consoletxt("Already Notified - $alert $extra") . "\n"; 
	    };
	} else {
	    my $insert_id = &ProcessStart($vid->{$k},$db_key,$title,$platform,$orig_user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year);
	    &Notify($alert,$extra,'start');
	    &SetNotified($insert_id);
	}
    }
}

#############################################################################################################################


sub Notify() {
    my $alert = shift;
    my $extra = shift;
    my $type = shift;
    if ($notify_started && $type =~ /start/ ||	$notify_stopped && $type =~ /stop/) {
	if ($notify->{'prowl'}->{'enabled'}) {	   &NotifyProwl($alert,$extra);}
	if ($notify->{'pushover'}->{'enabled'}) {     &NotifyPushOver($alert,$extra); }
    }
    
    
    my $console = &consoletxt("$date: $alert $extra"); 
    if ($debug) {	print $console ."\n";    }
    
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
    my $cmd = "select * from processed where notified = 1 and stopped is not null";
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
    
    my @p = split(':',shift);
    $prowl{'application'} .= ' - ' . shift(@p);
    $prowl{'event'} = join(':',@p);
    
    $prowl{'notification'} = shift;
    
    $prowl{'priority'} ||= 0;
    $prowl{'application'} ||= $appname;
    $prowl{'url'} ||= "";
    
    # URL encode our arguments
    $prowl{'application'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'event'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'notification'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    
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
	return duration_exact($diff);
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
        -stats             show total watched time and show total watched time per day
        -user=...          limit output to a specific user. Must be exact, case-insensitive

   -watching=...      print content being watched

   -show_xml          show xml result from api query
   -debug             hit and miss - not very useful

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


=item B<-stats>

* only works with -watched

show total watched time and show total watched time per day

=item B<-user>

* works with -watched and -watching

limit output to a specific user. Must be exact, case-insensitive

=item B<-watching>

Print a list of content currently being watched

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


