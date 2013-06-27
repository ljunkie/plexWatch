#!/usr/bin/perl -w

##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified 2013-06-26
#
# https://github.com/ljunkie/plexWatch
##########################################

use strict;
use LWP::UserAgent;
use WWW::Curl::Easy; ## might change this back to LWP
use XML::Simple;
use DBI;

my $server = 'localhost'; ## IP of PMS - or localhost
my $port = 32400;         ## port of PMS

my $notify_started = 1;   ## notify when a stream is started (first play)
my $notify_stopped = 1;   ## notify when a stream is stopped

my $appname = 'plexWatch';

## Notification Options
my $notify = {

    'file' => {
	'enabled' => 1,  ## 0 or 1 - set to 1 to enable File Logging
	'filename' => $appname . '.log', ## default is plexWatch.log
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

my $debug = 0; ## doesn't do much.. seriously


########################################## END CONFIG #######################################################




my $date = localtime;
my $dbh = &InitalizeDB();    ## Initialize sqlite db
my $vid = &GetSessions();    ## query API for current streams
my $started = &GetStarted(); ## query streams already started/not stopped
my $playing = ();            ## container of now playing id's - used for stopped status/notification

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
	    my $start_epoch = localtime($started->{$k}->{time});
	    my $alert = sprintf('%s stopped watching: %s', $started->{$k}->{user}, $started->{$k}->{title});
	    my $extra = sprintf("\nplatform: %s\n started: %s", $started->{$k}->{platform}, $start_epoch);
	    &Notify($alert,$extra,'stop');
	    &SetStopped($started->{$k}->{id});
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
    my $extra = sprintf("%s\n rated: %s\n year: %s\n user: %s\n platform: %s\n\n sumary: %s", $extra_title, $rating, $year, $user, $platform, $summary);
    
    if ($started->{$db_key}) {
	##if (&CheckNotified($db_key)) { old -- we now have started container (streams already notified and not stopped)
	if ($debug) { print "Already Notified - $alert\n"; }
    } else {
	my $insert_id = &ProcessStart($db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year);
	&Notify($alert,$extra,'start');
	&SetNotified($insert_id);
    }
}

sub Notify() {
    my $alert = shift;
    my $extra = shift;
    my $type = shift;
    if ($notify_started && $type =~ /start/ ||	$notify_stopped && $type =~ /stop/) {
	if ($notify->{'prowl'}->{'enabled'}) {	   &NotifyProwl($alert,$extra);}
	if ($notify->{'prowl'}->{'enabled'}) {     &NotifyPushOver($alert,$extra); }
    }
    
    my $console = "$date: $alert $extra";
    $console =~ s/\n\n/\n/g;
    $console =~ s/\n/,/g;
    $console =~ s/,$//; # get rid of last comma
    $console =~ s/[^[:ascii:]]+//g; 
    if ($debug) {	print $console ."\n";    }
    
    ## file logging
    if ($notify->{'file'}->{'enabled'}) {	
	open FILE, ">>", $notify->{'file'}->{'filename'}  or die $!;
	print FILE "$console\n";
	close(FILE);
    }

}

sub ProcessStart() {
    my ($db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year) = @_;
    $orig_title =~ s/\'/\'\'/g;
    $orig_title_ep =~ s/\'/\'\'/g;
    $summary =~ s/\'/\'\'/g;
    $platform =~ s/\'/\'\'/g;
    $title =~ s/\'/\'\'/g;
    $user =~ s/\'/\'\'/g;
    $rating =~ s/\'/\'\'/g;
    my $cmd = "insert into processed (session_id,title,platform,user,orig_title,orig_title_ep,genre,episode,season,summary,rating,year) values ('$db_key','$title','$platform','$user','$orig_title','$orig_title_ep','$genre','$episode','$season','$summary','$rating','$year')";
    my $sth2 = $dbh->prepare($cmd);
    $sth2->execute or die("Unable to execute query: $dbh->errstr\n");
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
    if ($db_key) {
	my $cmd = "update processed set stopped = 1 where id = '$db_key'";
	my $sth = $dbh->prepare($cmd);
	$sth->execute or die("Unable to execute query: $dbh->errstr\n");
    }
}

sub InitalizeDB() {
    my $dbh = DBI->connect("dbi:SQLite:dbname=./plexWatch.db","","");
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{'processed'}) { }
    else {
        my $cmd = "CREATE TABLE processed (id INTEGER PRIMARY KEY, session_id text, time timestamp default (strftime('%s', 'now')), 
user text, 
platform text, 
title text, 
orig_title text,
orig_title_ep text,
episode integer,
season integer,
year text,
rating text,
genre text,
summary text,
notified INTEGER,
stopped INTEGER
 );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
    }
    return $dbh;
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
