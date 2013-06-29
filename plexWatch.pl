#!/usr/bin/perl -w

##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified: 2013-06-29
#
#  Version: 0.0.5
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

my $data_dir = '/opt/plexWatch/'; ## to store the DB, logfile - can be the same as this script

my $server = 'localhost'; ## IP of PMS - or localhost
my $port = 32400;         ## port of PMS

my $notify_started = 1;   ## notify when a stream is started (first play)
my $notify_stopped = 1;   ## notify when a stream is stopped

my $appname = 'plexWatch';

## Notification Options
my $notify = {

    'file' => {
	'enabled' => 1,  ## 0 or 1 - set to 1 to enable File Logging
	'filename' => "$data_dir/$appname.log", ## default is plexWatch.log
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
    my %seen_a = ();
    if (keys %{$is_watched}) {
	print "\n";
	#foreach my $k (keys %{$is_watched}) {
	foreach my $k (sort { 
	    $is_watched->{$a}->{user} cmp $is_watched->{$b}->{'user'} ||
		$is_watched->{$a}->{time} cmp $is_watched->{$b}->{'time'} 
		       } (keys %{$is_watched}) ) {
	    if (!$seen{$is_watched->{$k}->{user}}) {
		$seen{$is_watched->{$k}->{user}} = 1;
		print "\nUser: " . $is_watched->{$k}->{user} . "\n";
	    }
	    ## only show one watched status on movie/show per day -- in case of restart/resumes..
	    my ($sec, $min, $hour, $day,$month,$year) = (localtime($is_watched->{$k}->{time}))[0,1,2,3,4,5]; 
	    my $skey = $year.$month.$day.$is_watched->{$k}->{title};
	    if (!$seen{$skey}) {
		$seen{$skey} = 1;
		
		my $time = localtime ($is_watched->{$k}->{time} );
		my $duration = &getDuration($is_watched->{$k}->{time},$is_watched->{$k}->{stopped});
		my $alert = sprintf(' %s: %s watched: %s [duration: %s]', $time,$is_watched->{$k}->{user}, $is_watched->{$k}->{title}, $duration);
		
		#my $extra = sprintf("rated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s",  $is_watched->{$k}->{rating}, $is_watched->{$k}->{year}, $is_watched->{$k}->{user}, $is_watched->{$k}->{platform}, $is_watched->{$k}->{summary});
		print $alert . "\n";
		#print $extra . "\n";
	    }
	}
    } else {	    print "\n\n* nothing watched\n";	}
    print "\n";
}

## print content being watched
if ($options{'watching'}) {
    
    my $in_progress = &GetInProgress();
    
    printf ("\n======================================= %s ========================================",'Watching');
    
    my %seen = ();
    if (keys %{$in_progress}) {
	print "\n";
	foreach my $k (sort { 
	    $in_progress->{$a}->{user} cmp $in_progress->{$b}->{'user'} ||
		$in_progress->{$a}->{time} cmp $in_progress->{$b}->{'time'} 
		       } (keys %{$in_progress}) ) {
	    if (!$seen{$in_progress->{$k}->{user}}) {
		$seen{$in_progress->{$k}->{user}} = 1;
		print "\nUser: " . $in_progress->{$k}->{user} . "\n";
	    }
	    
	    my $time = localtime ($in_progress->{$k}->{time} );
	    my $alert = sprintf(' %s: %s is watching: %s', $time,$in_progress->{$k}->{user}, $in_progress->{$k}->{title});
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
		my $alert = sprintf('%s is watching: %s', $info->{$k}->{user}, $info->{$k}->{title});
		my $extra = sprintf("Missed Notification\nStarted: %s\n\nrated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s", $time, $info->{$k}->{rating}, $info->{$k}->{year}, $info->{$k}->{user}, $info->{$k}->{platform}, $info->{$k}->{summary});
		
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
		
		my $duration = &getDuration($started->{$k}->{time},$stop_epoch);
		my $alert = sprintf('%s stopped watching: %s', $started->{$k}->{user}, $started->{$k}->{title});
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
	if ($vid->{$k}->{Player}->{platform}) {	$platform .= $vid->{$k}->{Player}->{platform};    }
	if ($vid->{$k}->{Player}->{title}) {	$platform .= ' - ' . $vid->{$k}->{Player}->{title};    }
	my $user = (split('\@',$vid->{$k}->{User}->{title}))[0];
	if (!$user) {	$user = 'Local';    }
	my $db_key = $k . '_' . $vid->{$k}->{key} . '_' . $user;
	
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
	    $extra_title .= ' episode: s'.$season.'e'.$episode;
	}
	
	if ($vid->{$k}->{'type'} =~ /movie/) {
	    ## to fix.. multiple genres
	    #if (defined($vid->{$k}->{Genre})) {	    $title .= ' ['.$vid->{$k}->{Genre}->{tag}.']';	}
	    $title .= ' ['.$year.']';
	    $title .= ' ['.$rating.']';
	    $extra_title = '';
	    #$summary = $vid->{$k}->{tagline};
	}
	
	my $alert = sprintf('%s is watching: %s', $user, $title);
	my $extra = sprintf("%s\n rated: %s\n year: %s\n user: %s\n platform: %s\n\n summary: %s", $extra_title, $rating, $year, $user, $platform, $summary);
	
	if ($started->{$db_key}) {
	    ##if (&CheckNotified($db_key)) { old -- we now have started container (streams already notified and not stopped)
	    if ($debug) { 
		my $insert_id = &ProcessStart($vid->{$k},$db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year);
		print &consoletxt("Already Notified - $alert $extra") . "\n"; 
	    };
	} else {
	    my $insert_id = &ProcessStart($vid->{$k},$db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year);
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
    ## update any old colums that just had 1 set for stopped
    $dbh->do("update processed set stopped = time where stopped = 1");

}

sub NotifyProwl() {
    ## modified from: https://www.prowlapp.com/static/prowl.pl
    my %prowl = %{$notify->{prowl}};
    
    my @p = split(':',shift);
    $prowl{'application'} .= ' - ' . $p[0];
    $prowl{'event'} = $p[1];
    
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
    my $response = $ua->post( "https://api.pushover.net/1/messages.json", [
				  "token" => $po{'token'},
				  "user" => $po{'user'},
				  "sound" => $po{'sound'},
				  "title" => $po{'title'},
				  "message" => "hello world",
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

limit watched status output to content started AFTER said date/time

Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

   -start=2013-06-29
   -start="2013-06-29 8:00pm"
   -start="today"
   -start="today at 8:30pm"
   -start="last week"
   -start=... give it a try and see what you can use :)

=item B<-stop>

limit watched status output to content started BEFORE said date/time

Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

   -stop=2013-06-29
   -stop="2013-06-29 8:00pm"
   -stop="today"
   -stop="today at 8:30pm"
   -stop="last week"
   -stop=... give it a try and see what you can use :)

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


