#!/usr/bin/perl

my $version = '0.0.20-dev-decoded-content';
my $author_info = <<EOF;
##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified: 2013-09-15 00:04 PST
#
#  Version: $version
# https://github.com/ljunkie/plexWatch
##########################################
EOF

use strict;
use LWP::UserAgent;
use XML::Simple;
use DBI;
use Time::Duration;
use Getopt::Long;
use Pod::Usage;
use Fcntl qw(:flock);
use Time::ParseDate;
use POSIX qw(strftime);
use File::Basename;
use warnings;
use open qw/:std :utf8/; ## default encoding of these filehandles all at once (binmode could also be used) 
use utf8;
#use Encode;


## load config file
my $dirname = dirname(__FILE__);
if (!-e $dirname .'/config.pl') {
    print "\n** missing file $dirname/config.pl. Did you move edit config.pl-dist and copy to config.pl?\n\n";
    exit;
}
do $dirname.'/config.pl';
use vars qw/$data_dir $server $port $appname $user_display $alert_format $notify $push_titles $backup_opts $myPlex_user $myPlex_pass $server_log $log_client_ip $debug_logging $watched_show_completed $watched_grouping_maxhr $count_paused/; 
if (!$data_dir || !$server || !$port || !$appname || !$alert_format || !$notify) {
    print "config file missing data\n";
    exit;
}
## end

############################################
## Advanced Options (override in config.pl)

## always display a 100% watched show. I.E. if user watches show1 100%, then restarts it and stops at < 90%, show two lines
$watched_show_completed = 1 if !defined($watched_show_completed); 

## how many hours between starts of the same show do we allow grouping? 24 is max (3 hour default)
$watched_grouping_maxhr = 3 if !defined($watched_grouping_maxhr);      

## end
############################################


## for now, let's warn the user if they have enabled logging of clients IP's and the server log is not found
if ($server_log && !-f $server_log) {
    print "warning: \$server_log is specified in config.pl and $server_log does not exist (required for logging of the clients IP address)\n" if $log_client_ip;
}

## ONLY Load modules if used
if (&ProviderEnabled('twitter')) {
    require Net::Twitter::Lite::WithAPIv1_1;
    require Net::OAuth;
    require Scalar::Util;
    Net::Twitter::Lite::WithAPIv1_1->import(); 
    Net::OAuth->import();
    Scalar::Util->import('blessed');
}

if (&ProviderEnabled('GNTP')) {
    require Growl::GNTP;
    Growl::GNTP->import();
}

if (&ProviderEnabled('EMAIL')) {
    #require MIME::Lite; mime::lite sucks
    #MIME::Lite->import();
    require Net::SMTP::TLS;
    Net::SMTP::TLS->import();
}

if ($log_client_ip) {
    require File::ReadBackwards;
    File::ReadBackwards->import();
}

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
    'progress' => 'progress of video [only available/correct on --watching and stop events]',
    'time_left' => 'progress of video [only available/correct on --watching and stop events]',
    'streamtype' => 'T or D - for Transcoded or Direct',
    'transcoded' => '1 or 0 - if transcoded',
    'state' => 'playing, paused or buffering [ or stopped ] (useful on --watching)',
    'percent_complete' => 'Percent of video watched -- user could have only watched 5 minutes, but skipped to end = 100%',
    'ip_address' => 'Client IP Address',
};

if (!-d $data_dir) {
    print "\n** Sorry. Please create your datadir $data_dir\n\n";
    exit;
}

## place holder to back off notifications per provider
my $provider_452 = ();


# Grab our options.
my %options = ();
GetOptions(\%options, 
           'watched',
           'nogrouping',
           'stats',
           'user:s',
           'exclude_user:s@',
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
	   'recently_added:s',
	   'version',
	   'backup',
	   'show_xml',
           'help|?'
    ) or pod2usage(2);
pod2usage(-verbose => 2) if (exists($options{'help'}));

if ($options{version}) {
    print "\n\tVersion: $version\n\n";
    print "$author_info\n";
    exit;
}


my $debug = $options{'debug'};
my $debug_xml = $options{'show_xml'};

## ONLY load modules if used
if ($options{debug}) {
    require Data::Dumper;
    Data::Dumper->import(); 
    require diagnostics;
    diagnostics->import();
}


if ($options{'format_options'}) {
    print "\nFormat Options for alerts\n";
    print "\n\t    --start='" . $alert_format->{'start'} ."'";
    print "\n\t     --stop='" . $alert_format->{'stop'} ."'";
    print "\n\t  --watched='" . $alert_format->{'watched'} ."'";
    print "\n\t --watching='" . $alert_format->{'watching'} ."'";
    print "\n\n";
    
    foreach my $k (keys %{$format_options}) {
	printf("%20s %s\n", "{$k}", $format_options->{$k});
    }
    print "\n";
    exit;
}

## reset format if specified
$alert_format->{'start'} = $options{'format_start'} if $options{'format_start'};
$alert_format->{'stop'} = $options{'format_stop'} if $options{'format_stop'};
$alert_format->{'watched'} = $options{'format_watched'} if $options{'format_watched'};
$alert_format->{'watching'} = $options{'format_watching'} if $options{'format_watching'};

my %notify_func = &GetNotifyfuncs();
my $push_type_titles = &GetPushTitles();

## Check LOCK 
# only allow one script run at a time. 
# Before initDB
my $script_fh;
&CheckLock();
## END

my $dbh = &initDB(); ## Initialize sqlite db - last
&BackupSQlite; ## check if the SQLdb needs to be backed up

my $PMS_token = &PMSToken(); # sets token if required

########################################## START MAIN #######################################################

## show what the notify alerts will look like
if  (defined($options{test_notify})) {
    &RunTestNotify();
    exit;
}

####################################################################
## RECENTLY ADDED 
if ($options{'recently_added'}) {
    my ($hkey);
    my @want;
    ## TO NOTE: plex used show and episode off an on. code for both
    if ($options{'recently_added'} =~ /movie/i) {
	push @want , 'movie';
	$hkey = 'Video';
    } 
    if ($options{'recently_added'} =~ /show|tv|episode/i) {
	push @want , 'show';
	$hkey = 'Video';
    }
    
    ## maybe someday.. TODO
    #}    elsif ($options{'recently_added'} =~ /artists|music/i) {
    #	$want = 'artist';
    #	$hkey = 'Directory';
    
    if (!@want) {
	#print "\n 'recently_added' must be: movie, show or artist\n\n";
	print "\n 'recently_added' must be: 'movie' or 'show' -- or a comma separated list \n\n";
	exit;
    }
    
    my $plex_sections = &GetSectionsIDs(); ## allow for multiple sections with the same type (movie, show, etc) -- or different types (2013-08-01)
    my @merged = ();
    foreach my $w (@want) {
	foreach my $v (@{$plex_sections->{'types'}->{$w}}) {   push (@merged, $v); }
    }
    
    my $info = &GetRecentlyAdded(\@merged,$hkey);
    my $alerts = (); # containers to push alerts from oldest -> newest
    
    my %seen;
    foreach my $k (keys %{$info}) {
	
	$seen{$k} = 1; ## alert seen
	if (!ref($info->{$k})) {
	    if ($debug) {
		print "Skipping KEY '$k' (expected key =~ '/library/metadata/###') -- it's not a hash ref?\n";
		print "\$info->{'$k'} is not a hash ref?\n";
		print Dumper($info->{$k}) if $options{debug};
	    }
	    next;
	}
	
	my $item = &ParseDataItem($info->{$k});
	my $res = &RAdataAlert($k,$item);
	$alerts->{$item->{addedAt}.$k} = $res;
    }


    ## RA backlog - make sure we have all alerts -- some might has been added previously but notification failed and newer content has purged the results above
    my $ra_done = &GetRecentlyAddedDB();
    my $push_type = 'push_recentlyadded';
    foreach my $provider (keys %{$notify}) {
	next if (!&ProviderEnabled($provider,$push_type));
	#next if ( !$notify->{$provider}->{'enabled'} || !$notify->{$provider}->{$push_type}); ## skip provider if not enabled
	foreach my $key (keys %{$ra_done}) {
	    next if $seen{$key}; ## already in alerts hash
	    next if ($ra_done->{$key}->{$provider}); ## provider already notified

	    ## we passed checks -- let's process this old/failed notification
	    my $data = &GetItemMetadata($key,1);
	    
	    ## if result is not a href ( it's possible the video has been removed from the PMS ) 
	    if (!ref($data)) {
		##  maybe we got 404 -- I.E. old/removed video.. set at 404 -> not found
		if ($data =~ /404/) {
		    &SetNotified_RA($provider,$key,404);
		    next;
		}
		## any other results we care about? maybe later
	    }
	    
	    else {
		my $item = &ParseDataItem($data);
		
		## for back log -- verify we are only checking the type we have specified
		my %wmap = map { $_ => 1 } @want;
		next if $data->{'type'} =~ /episode/ && !exists($wmap{'show'}); ## next if episode and current task is not a show
		next if $data->{'type'} =~ /movie/ && !exists($wmap{'movie'}); ## next if episode and current task is not a show

		## check age of notification. -- allow two days ( we will keep trying to notify for 2 days.. if we keep failing.. we need to skip this)
		my $age = time()-$ra_done->{$key}->{'time'};
		my $ra_max_fail_days = 2; ## TODO: advanced config options?
		if ($age > 86400*$ra_max_fail_days) {
		    ## notification is OLD .. set notify = 2 to exclude from processing
		    my $msg = "Could not notify $provider on [$key] $item->{'title'} for " . &durationrr($age) . " -- setting as old notification/done";
		    &ConsoleLog($msg,,1);
		    &SetNotified_RA($provider,$key,2);
		}
		
		if ($alerts->{$item->{addedAt}.$key}) {
		    ## redundant code from above hash %seen 
		    #print "$item->{'title'} is already in current releases... nothing missed\n";
		} else {
		    print "$item->{'title'} is NOT in current releases -- we failed to notify previously, so trying again\n" if $options{'debug'};
		    my $res = &RAdataAlert($key,$item);
		    $alerts->{$item->{addedAt}.$key} = $res;
		}
	    }
	    
	}
	
    }

    &ProcessRAalerts($alerts) if ref($alerts);
}


sub RAdataAlert() {
    my $item_id = shift;
    my $item = shift;

    my $result;
    
    my $add_date = &twittime($item->{addedAt});
    
    my $debug_done = '';
    $debug_done .= $item->{'grandparentTitle'} . ' - ' if $item->{'grandparentTitle'};
    $debug_done .= $item->{'title'} if $item->{'title'};
    $debug_done .= " [$add_date]";
    

    my $alert = 'unknown type';
    my ($alert_url,$alert_short);
    my $media;
    $media .= $item->{'videoResolution'}.'p ' if $item->{'videoResolution'};
    $media .= $item->{'audioChannels'}.'ch' if $item->{'audioChannels'};
    ##my $twitter; #twitter sucks... has to be short. --- might use this later.
    if ($item->{'type'} eq 'show' || $item->{'type'} eq 'episode') {
	$alert = $item->{'title'};
	$alert_short = $item->{'title'};
	$alert .= " [$item->{'contentRating'}]" if $item->{'contentRating'};
	$alert .= " [$item->{'year'}]" if $item->{'year'};
	if ($item->{'duration'} && ($item->{'duration'} =~ /\d+/ && $item->{'duration'} > 1000)) {
	    $alert .=  ' '. sprintf("%.0f",$item->{'duration'}/1000/60) . 'min';
	}
	$alert .= " [$media]" if $media;
	$alert .= " [$add_date]";
	#$twitter = $item->{'title'};
	#$twitter .= " [$item->{'year'}]";
	#$twitter .=  ' '. sprintf("%.02d",$item->{'duration'}/1000/60) . 'min';
	#$twitter .= " [$media]" if $media;
	#$twitter .= " [$add_date]";
	$alert_url .= ' http://www.imdb.com/find?s=tt&q=' . urlencode($item->{'imdb_title'});
    }
    if ($item->{'type'} eq 'movie') {
	$alert = $item->{'title'};
	$alert_short = $item->{'title'};
	$alert .= " [$item->{'contentRating'}]" if $item->{'contentRating'};
	$alert .= " [$item->{'year'}]" if $item->{'year'};
	if ($item->{'duration'} && ($item->{'duration'} =~ /\d+/ && $item->{'duration'} > 1000)) {
	    $alert .=  ' '. sprintf("%.0f",$item->{'duration'}/1000/60) . 'min';
	}
	$alert .= " [$media]" if $media;
	$alert .= " [$add_date]";
	#$twitter = $alert; ## movies are normally short enough.
	$alert_url .= ' http://www.imdb.com/find?s=tt&q=' . urlencode($item->{'imdb_title'});
    }
    
    #$alert =~ s/[^[:ascii:]]+//g;  ## remove non ascii ( now UTF8 )
    
    $result->{'alert'} = $alert;
    $result->{'alert_short'} = $alert_short;
    #$result->{'alert'} = 'NEW: '.$alert;
    #$result->{'alert_short'} = 'NEW: '.$alert_short;
    $result->{'item_id'} = $item_id;
    $result->{'debug_done'} = $debug_done;
    $result->{'alert_url'} = $alert_url;

    return $result;
}


###############################################################################################################3
## --watched, --watching, --stats

####################################################################
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
##--watched
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
    my %seen_epoch = ();
    my %seen_cur = ();
    my %seen_user = ();
    my %stats = ();
    my $ntype = 'watched';
    my %completed = ();
    my %seenc = (); ## testing
    if (keys %{$is_watched}) {
	print "\n";
	foreach my $k (sort {$is_watched->{$a}->{user} cmp $is_watched->{$b}->{'user'} || 
				 $is_watched->{$a}->{time} cmp $is_watched->{$b}->{'time'} } (keys %{$is_watched}) ) {
	    ## use display name 
	    my ($user,$orig_user) = &FriendlyName($is_watched->{$k}->{user},$is_watched->{$k}->{platform});
	    
	    ## skip/exclude users --user/--exclude_user
	    my $skip = 1;
	    ## --exclude_user array ref
	    next if ( grep { $_ =~ /$is_watched->{$k}->{'user'}/i } @{$options{'exclude_user'}});
	    next if ( $user  && grep { $_ =~ /^$user$/i } @{$options{'exclude_user'}});
	    
	    if ($options{'user'}) {
		$skip = 0 if $user =~ /^$options{'user'}$/i; ## user display (friendly) matches specified 
		$skip = 0 if $orig_user =~ /^$options{'user'}$/i; ## user (non friendly) matches specified
	    }  else {	$skip = 0;    }

	    next if $skip;

	    ## only show one watched status on movie/show per day (default) -- duration will be calculated from start/stop on each watch/resume
	    ## --nogrouping will display movie as many times as it has been started on the same day.
	    
	    ## to cleanup - maybe subroutine
	    my ($sec, $min, $hour, $day,$month,$year) = (localtime($is_watched->{$k}->{time}))[0,1,2,3,4,5]; 
	    $year += 1900;
	    $month += 1;
	    my $serial = parsedate("$year-$month-$day 00:00:00");

	    #my $skey = $is_watched->{$k}->{user}.$year.$month.$day.$is_watched->{$k}->{title};
	    my $skey = $user.$year.$month.$day.$is_watched->{$k}->{title};
	    
	    ## get previous day -- see if video same title was watched then -- if so -- group them together for display purposes. stats and --nogrouping will still show the break
	    my ($sec2, $min2, $hour2, $day2,$month2,$year2) = (localtime($is_watched->{$k}->{time}-86400))[0,1,2,3,4,5]; 
	    $year2 += 1900;
	    $month2 += 1;
	    

	    #my $skey2 = $is_watched->{$k}->{user}.$year2.$month2.$day2.$is_watched->{$k}->{title};
	    my $skey2 = $user.$year2.$month2.$day2.$is_watched->{$k}->{title};
	    if ($seen{$skey2}) {		$skey = $skey2;	    }
	    
	    my $orig_skey = $skey; ## DO NOT MODIFY THIS

	    
	    ## Do NOT group content if the percent watched is 100% -- this will group everything up to 100% and start a new line...
	    #    * will now show that the viewer had watched the video completely (line1) and restarted it (line2)
	    
	    #just testing out grouping if percent_complete == 100
	    # if ($seenc{$orig_skey} && $seenc{$orig_skey} == 2) {$info->{'percent_complete'}  = 100;  }
	    # if ($seenc{$orig_skey} && $seenc{$orig_skey} == 5) {$info->{'percent_complete'}  = 100;  }
	    # $seenc{$orig_skey}++;
	    
	    my $is_completed = 0;
	    if ($watched_show_completed) {
		my $paused = &getSecPaused($k);
		my $info = &info_from_xml($is_watched->{$k}->{'xml'},$ntype,$is_watched->{$k}->{'time'},$is_watched->{$k}->{'stopped'},$paused);
		$skey = $skey . $completed{$orig_skey} if $completed{$orig_skey};
		if ($info->{'percent_complete'} > 99) {
		    my $d_out = "$is_watched->{$k}->{title} watched 100\% by $user on $year-$month-$day - starting a new line (more than once)\n";
		    $completed{$orig_skey}++;
		    $is_completed = 1; ## skey-incremented -- we can skip other skey checks
		    &DebugLog($d_out) if $completed{$orig_skey} > 1;
		}
	    }
	    # end 100% grouping
	    
	    ## split lines if start/restart > $watched_grouping_maxhr
	    #    * do not just blindly group by day.. the start/restart should be NO MORE than a few hours apart ($watched_grouping_maxhr)
	    if (!$is_completed) {
		$skey = $seen_cur{$orig_skey}  if $seen_cur{$orig_skey};                 ## if we have set $seen_cur - reset skey to that
		$seen_epoch{$skey} = $is_watched->{$k}->{time}  if !$seen_epoch{$skey};  ## set epoch for skey (if not set)
		my $diff = $is_watched->{$k}->{time}-$seen_epoch{$skey};                 ## diff between last start and this start
		
		if ($diff > (60*60)*($watched_grouping_maxhr)) {
		    my $d_out = &durationrr($diff) . 
			" between start,restart of '$is_watched->{$k}->{title}' for $user on $year-$month-$day: starting a new line\n";
		    &DebugLog($d_out);
		    $skey = $orig_skey . $is_watched->{$k}->{time}; ## increment the skey
		    $seen_cur{$orig_skey} = $skey;                  ## set what the skey will be for future
		} 
		$seen_epoch{$skey} = $is_watched->{$k}->{time};  ## set the last epoch seen for this skey
	    }
	    ## END split if > $watched_grouping_maxhr
	    
	    ## stat -- quick and dirty -- to clean up later
	    $stats{$user}->{'total_duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    $stats{$user}->{'duration'}->{$serial} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    ## end
	    
	    next if !$options{'watched'};
	    next if $is_watched->{$k}->{xml} =~ /<opt><\/opt>/i; ## bug -- fixed in 0.0.19
	    my $paused = &getSecPaused($k);
	    if ($options{'nogrouping'}) {
		if (!$seen_user{$user}) {
		    $seen_user{$user} = 1;
		    print "\nUser: " . $user;
		    print ' ['. $orig_user .']' if $user ne $orig_user;
		    print "\n";
		}
		my $time = localtime ($is_watched->{$k}->{time} );
		my $info = &info_from_xml($is_watched->{$k}->{'xml'},$ntype,$is_watched->{$k}->{'time'},$is_watched->{$k}->{'stopped'},$paused);
		$info->{'ip_address'} = $is_watched->{$k}->{ip_address};
		my $alert = &Notify($info,1); ## only return formated alert
		printf(" %s: %s\n",$time, $alert);
	    } else {
		if (!$seen{$skey}) {
		    $seen{$skey}->{'ip_address'} = $is_watched->{$k}->{ip_address};
		    $seen{$skey}->{'time'} = $is_watched->{$k}->{time};
		    $seen{$skey}->{'xml'} = $is_watched->{$k}->{xml};
		    $seen{$skey}->{'user'} = $user;
		    $seen{$skey}->{'orig_user'} = $orig_user;
		    $seen{$skey}->{'stopped'} = $is_watched->{$k}->{stopped};
		    if (!$count_paused) {
			$seen{$skey}->{'duration'} += ($is_watched->{$k}->{stopped}-$is_watched->{$k}->{time})-$paused;
		    } else {
			$seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
		    }

		} else {
		    ## if same user/same movie/same day -- append duration -- must of been resumed
		    $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
		    ## update the group with the most recent XML
		    $seen{$skey}->{'xml'} = $is_watched->{$k}->{xml};
		    
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
		print "\nUser: " . $seen{$k}->{user};
		print ' ['. $seen{$k}->{orig_user} .']' if $seen{$k}->{user} ne $seen{$k}->{orig_user};
		print "\n";
	    }
	    my $time = localtime ($seen{$k}->{time} );
	    
	    my $info = &info_from_xml($seen{$k}->{xml},$ntype,$seen{$k}->{'time'},$seen{$k}->{'stopped'},0,$seen{$k}->{'duration'});
	    $info->{'ip_address'} = $seen{$k}->{ip_address};
	    my $alert = &Notify($info,1); ## only return formated alert
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


## no options -- we can continue.. otherwise --stats, --watched, --watching or --notify MUST be specified
if (%options && !$options{'notify'} && !$options{'stats'} && !$options{'watched'} && !$options{'watching'} && !$options{'recently_added'} ) {
    print "\n* Skipping any Notifications -- command line options set, use '--notify' or supply no options to enable notifications\n";
    exit;
}

## set notify to 1 if we call --watching ( we need to either log start/update/stop current progress)
$options{'notify'} = 1 if $options{'watching'};
			   

#################################################################
## Notify -notify || no options = notify on watch/stopped streams
##--notify
if (!%options || $options{'notify'}) {
    my $live = &GetSessions();    ## query API for current streams
    my $started= &GetStarted(); ## query streams already started/not stopped
    my $playing = ();            ## container of now playing id's - used for stopped status/notification
    
    ###########################################################################
    ## nothing being watched.. verify all notification went out
    ## this shouldn't happen ( only happened during development when I was testing -- but just in case )
    #### to fix
    if (!ref($live)) {
	my $un = &GetUnNotified();
	foreach my $k (keys %{$un}) {
	    if (!$playing->{$k}) {
		my $ntype = 'start';
		my $start_epoch = $un->{$k}->{time} if $un->{$k}->{time};
		my $stop_epoch = '';
		my $paused = &getSecPaused($k);
		my $info = &info_from_xml($un->{$k}->{'xml'},'start',$start_epoch,$stop_epoch,$paused);
		$info->{'ip_address'} = $un->{$k}->{ip_address};
		&Notify($info);
		&SetNotified($un->{$k}->{id});
		## another notification will go out about being stopped..
		## next run it will be marked as watched and notified
	    }
	}
    }
    ## end unnotified
    
    ## Quick hack to notify stopped content before start -- get a list of playing content
    foreach my $k (keys %{$live}) {
	my $user = (split('\@',$live->{$k}->{User}->{title}))[0];
	if (!$user) {	$user = 'Local';    }
	my $db_key = $k . '_' . $live->{$k}->{key} . '_' . $user;
	$playing->{$db_key} = 1;
    }
    
    ## Notify on any Stop
    ## Iterate through all non-stopped content and notify if not playing
    if (ref($started)) {
	foreach my $k (keys %{$started}) {
	    if (!$playing->{$k}) {
		my $start_epoch = $started->{$k}->{time} if $started->{$k}->{time};
		my $stop_epoch = time();
		my $paused = &getSecPaused($k);
		my $info = &info_from_xml($started->{$k}->{'xml'},'stop',$start_epoch,$stop_epoch,$paused);
		$info->{'ip_address'} = $started->{$k}->{ip_address};
		&Notify($info);
		&SetStopped($started->{$k}->{id},$stop_epoch);
	    }
	}
    }
    
    ## Notify on start/now playing
    foreach my $k (keys %{$live}) {
	my $start_epoch = time();
	my $stop_epoch = ''; ## not stopped yet
	my $info = &info_from_xml(XMLout($live->{$k}),'start',$start_epoch,$stop_epoch,0);

	## for insert 
	my $db_key = $k . '_' . $live->{$k}->{key} . '_' . $info->{orig_user};
	
	## these shouldn't be neede any more - to clean up as we now use XML data from DB
	$info->{'orig_title'} = $live->{$k}->{title};
	$info->{'orig_title_ep'} = '';
	$info->{'episode'} = '';
	$info->{'season'} = '';
	$info->{'genre'} = '';
	if ($live->{$k}->{grandparentTitle}) {
	    $info->{'orig_title'} = $live->{$k}->{grandparentTitle};
	    $info->{'orig_title_ep'} = $live->{$k}->{title};
	    $info->{'episode'} = $live->{$k}->{index};
	    $info->{'season'} = $live->{$k}->{parentIndex};
	    if ($info->{'episode'} < 10) { $info->{'episode'} = 0 . $info->{'episode'};}
	    if ($info->{'season'} < 10) { $info->{'season'} = 0 . $info->{'season'}; }
	}
	## end unused data to clean up
	
	## ignore content that has already been notified
	## However, UPDATE the XML in the DB
	
	
	if ($started->{$db_key}) {
	    $info->{'ip_address'} = $started->{$db_key}->{ip_address};
	    ## try and locate IP address on each run ( if empty )
	    if (!$info->{'ip_address'}) {
		$info->{'ip_address'} = &LocateIP($info) if ref $info;
	    }
	    my $state_change = &ProcessUpdate($live->{$k},$db_key,$info->{'ip_address'}); ## update XML
	    
	    ## notify on pause/resume -- only providers with push_resume or push_pause will be notified
	    if ($state_change) {
		&DebugLog($info->{'user'} . ':' . $info->{'title'} . ': state change [' . $info->{'state'} . '] notify called');
		&Notify($info,'',1);
	    }
	    
	    if ($debug) { 
		&Notify($info);
		print &consoletxt("Already Notified -- Sent again due to --debug") . "\n"; 
	    };
	} 
	## unnotified - insert into DB and notify
	else {
	    ## quick and dirty hack for client IP address
	    $info->{'ip_address'} = &LocateIP($info) if ref $info;
	    ## end the dirty feeling
	    
	    my $insert_id = &ProcessStart($live->{$k},$db_key,$info->{'title'},$info->{'platform'},$info->{'orig_user'},$info->{'orig_title'},$info->{'orig_title_ep'},$info->{'genre'},$info->{'episode'},$info->{'season'},$info->{'summary'},$info->{'rating'},$info->{'year'},$info->{'ip_address'});
	    &Notify($info);
	    ## should probably have some checks to make sure we were notified.. TODO
	    &SetNotified($insert_id);
	}
    }
}


#####################################################
## print content being watched
##--watching
if ($options{'watching'}) {
    my $in_progress = &GetInProgress();
    my $live = &GetSessions();    ## query API for current streams
    
    printf ("\n======================================= %s ========================================",'Watching');
    
    my %seen = ();
    if (keys %{$in_progress}) {
	print "\n";
	foreach my $k (sort { $in_progress->{$a}->{user} cmp $in_progress->{$b}->{'user'} || $in_progress->{$a}->{time} cmp $in_progress->{$b}->{'time'} } (keys %{$in_progress}) ) {
	    ## use display name 
	    my ($user,$orig_user) = &FriendlyName($in_progress->{$k}->{user},$in_progress->{$k}->{platform});

	    ## skip/exclude users --user/--exclude_user
	    my $skip = 1;
	    ## --exclude_user array ref
	    next if ( grep { $_ =~ /$in_progress->{$k}->{'user'}/i } @{$options{'exclude_user'}});
	    next if ( $user  && grep { $_ =~ /^$user$/i } @{$options{'exclude_user'}});
	    
	    if ($options{'user'}) {
		$skip = 0 if $user =~ /^$options{'user'}$/i; ## user display (friendly) matches specified 
		$skip = 0 if $orig_user =~ /^$options{'user'}$/i; ## user (non friendly) matches specified
	    }  else {	$skip = 0;    }
	    
	    next if $skip;
	    
	    my $live_key = (split("_",$k))[0];
	    
	    
	    if (!$seen{$user}) {
		$seen{$user} = 1;
		print "\nUser: " . $user;
		print ' ['. $orig_user .']' if $user ne $orig_user;
		print "\n";
	    }
	    
	    my $time = localtime ($in_progress->{$k}->{time} );

	    ## switched to LIVE info
	    #my $info = &info_from_xml($in_progress->{$k}->{'xml'},'watching',$in_progress->{$k}->{time});


	    my $paused = &getSecPaused($k);
	    my $info = &info_from_xml(XMLout($live->{$live_key}),'watching',$in_progress->{$k}->{time},time(),$paused);
	    $info->{'ip_address'} = $in_progress->{$k}->{ip_address};

	    ## disabled - --watching calls --notify ( so this is redundant)
	    #&ProcessUpdate($live->{$live_key},$k); ## update XML  ## probably redundant as --watching calls --notify now -- (TODO)

	    ## overwrite progress and time_left from live -- should be pulling live xml above at some point
	    #$info->{'progress'} = &durationrr($live->{$live_key}->{viewOffset}/1000);
	    #$info->{'time_left'} = &durationrr(($info->{raw_length}/1000)-($live->{$live_key}->{viewOffset}/1000));
	    
	    my $alert = &Notify($info,1); ## only return formated alert
	    printf(" %s: %s\n",$time, $alert);
	}
	
    } else {	    print "\n * nothing in progress\n";	}
    print " \n";
}

#################################################### SUB #########################################################################

sub formatAlert() {
    my $info = shift;
    my $provider = shift;
    my $provider_multi = shift;
    
    ## n_prov_format: alert_format override in the config.pl per provider
    my $n_prov_format = {};
    if ($provider) {
	$n_prov_format = $notify->{$provider};
	$n_prov_format = $notify->{$provider}->{$provider_multi} if $provider_multi;
    }
    
    $info->{'ip_address'} = '' if !$info->{'ip_address'};
    
    my $type = $info->{'ntype'};
    my @types = qw(start watched watching stop paused resumed);
    my $format;
    foreach my $tkey (@types) {
	if ($type =~ /$tkey/i) {
	    $format = $alert_format->{$tkey}; # default alert formats per notify type
	    $format = $n_prov_format->{'alert_format'}->{$tkey} if $n_prov_format->{'alert_format'}->{$tkey}; # provider override
	}
    }
    if ($debug) { print "\nformat: $format\n";}

    my $regex = join "|", keys %{$info};
    $regex = qr/$regex/;
    $format =~ s/{($regex)}/$info->{$1}/g; ## regex replace variables
    $format =~ s/\[\]//g;                 ## trim any empty variable encapsulated in []
    $format =~ s/\s+/ /g;                 ## remove double spaces
    #$format =~ s/[^[:ascii:]]+//g;        ## remove non ascii ( now UTF8 )
    $format =~ s/\\n/\n/g;                ## allow \n to be an actual new line
    $format =~ s/{newline}/\n/g;                ## allow \n to be an actual new line

    
    ## special for now.. might make ths more useful -- just thrown together since email can include a ton of info
    if ($format =~ /{all_details}/i) {
	$format =~ s/\s*{all_details}\s*//i;
	$format .= sprintf("\n\n%10s %s\n","","-----All Details-----");
	my $f_extra;
	foreach my $key (keys %{$info} ) {
	    if (!ref($info->{$key})) {
		$format .= sprintf("%20s: %s\n",$key,$info->{$key}) if $info->{$key};
	    } else {
		$f_extra .= sprintf("\n\n%10s %s\n","","-----$key-----");
		foreach my $k2 (keys %{$info->{$key}} ) {
		    if (!ref($info->{$key}->{$k2})) {
			$f_extra .= sprintf("%20s: %s\n",$k2,$info->{$key}->{$k2});
		    }
		}
	    }
	}
	$format .= $f_extra if $f_extra;
    }
    return ($format);
}

sub ConsoleLog() {
    my $msg = shift;
    my $alert_options = shift;
    my $print = shift;

    my $prefix = '';
    
    if (ref($alert_options)) {
	if ($msg !~ /$alert_options->{'user'}/) {
	    $prefix .= $alert_options->{'user'} . ' ' if $alert_options->{'user'};
	    $prefix .= $push_type_titles->{$alert_options->{'push_type'}} . ' ' if $alert_options->{'push_type'};
	    $msg = $prefix . $msg;
	}
    }
    
    my $console;
    my $date = localtime;

    if ($debug || $print) {
	$console = &consoletxt("$date: DEBUG: $msg"); 
	print   $console ."\n";   
    } elsif ($options{test_notify}) {
	$console = &consoletxt("$date: DEBUG test_notify: $msg"); 
	print   $console ."\n";   
    } else {
	$console = &consoletxt("$date: $msg"); 
    }
    
    ## file logging
    if (&ProviderEnabled('file')) {
	open FILE, ">>", $notify->{'file'}->{'filename'}  or die $!;
	print FILE "$console\n";
	close(FILE);
	print "FILE Notification successfully logged.\n" if $debug;
	
    }
    return 1;
}

sub NotifyFile() {
    my $provider = 'file';

    #my $msg = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $msg = $alert;

    my $alert_options = shift;
    my $print = shift;
    
    my $prefix = '';
    
    if (ref($alert_options)) {
	if ($msg !~ /\b$alert_options->{'user'}\b/i) {
	    $prefix .= $alert_options->{'user'} . ' ' if $alert_options->{'user'};
	}
	if ($msg !~ /\b$push_type_titles->{$alert_options->{'push_type'}}\b/i) {
	    $prefix .= $push_type_titles->{$alert_options->{'push_type'}} . ' ' if $alert_options->{'push_type'};
	}
	$msg = $prefix . $msg if $prefix;
    }
    
    my $console;
    my $date = localtime;
    
    if ($debug || $print) {
	$console = &consoletxt("$date: DEBUG: $msg"); 
	print   $console ."\n";   
    } elsif ($options{test_notify}) {
	$console = &consoletxt("$date: DEBUG test_notify: $msg"); 
	print   $console ."\n";   
    } else {
	$console = &consoletxt("$date: $msg"); 
    }
    
    ## file logging
    if (&ProviderEnabled('file')) {
	open FILE, ">>", $notify->{'file'}->{'filename'}  or die $!;
	print FILE "$console\n";
	close(FILE);
	print "FILE Notification successfully logged.\n" if $debug;
	
    }
    return 1;
}




sub DebugLog() {
    ## still need to add this routine to many other places (TODO)
    my $msg = shift;
    my $print = shift;
    
    my $date = localtime;
    my $console = &consoletxt("$date: $msg"); 
    print   $console ."\n"     if ($debug || $print);
    
    if ($debug_logging) {
	open FILE, ">>", $data_dir . '/' . 'debug.log'  or die $!;
	print FILE "$console\n";
	close(FILE);
    }
}

sub Notify() {
    my $info = shift;
    my $ret_alert = shift;
    my $state_change = shift; ## we will check what the state is and notify accordingly

    my $dinfo = $info->{'user'}.':'.$info->{'title'};
    #&DebugLog($dinfo . ': '."ret_alert:$ret_alert, state_change:$state_change");
    
    my $type = $info->{'ntype'};


    ## to fix
    if ($state_change) {
	$type = "resumed" if $info->{'state'} =~ /playing/i;
	$type = "paused" if $info->{'state'} =~ /pause/i;
	$info->{'ntype'} = $type;
	&DebugLog($dinfo . ': '."state:$info->{'state'}, ntype:$type ");
    }
    
    my ($alert) = &formatAlert($info);
    
    ## --exclude_user array ref -- do not notify if user is excluded.. however continue processing -- logging to DB - logging to file still happens.
    return 1 if ( grep { $_ =~ /$info->{'orig_user'}/i } @{$options{'exclude_user'}});
    return 1 if ( grep { $_ =~ /$info->{'user'}/i } @{$options{'exclude_user'}});
    
    ## only return the alert - do not notify -- used for CLI to keep formatting the same
    return &consoletxt($alert) if $ret_alert;
        
    my $push_type;
    
    if ($type =~ /start/) {	$push_type = 'push_watching';    } 
    if ($type =~ /stop/)  {	$push_type = 'push_watched';     } 
    if ($type =~ /resume/)  {	$push_type = 'push_resumed';     } 
    if ($type =~ /pause/) {	$push_type = 'push_paused';      } 

    &DebugLog($dinfo . ': '.'push_type:' . $push_type);
    
    #my $alert_options = ();
    my $alert_options = $info; ## include $info href
    
    $alert_options->{'push_type'} = $push_type;
    foreach my $provider (keys %{$notify}) {
	if (&ProviderEnabled($provider,$push_type)) {
	    &DebugLog($dinfo . ': '.$provider . ' ' . $push_type . ' enabled -> sending notify');
	    $notify_func{$provider}->($info,$alert_options);
	    #$notify_func{$provider}->($alert,$alert_options);
	}
    }
}

sub ProviderEnabled() {
    my ($provider,$push_type) = @_;
    if (!$push_type) {
	## provider is multi ( GNTP )
	foreach my $k (keys %{$notify->{$provider}}) {
	    return 1 if (ref $notify->{$provider}->{$k} && $notify->{$provider}->{$k}->{'enabled'});
	}
	## provider is non-multi
	return 1 if $notify->{$provider}->{'enabled'};
    } 
    
    ## check provider and push type if supplied
    else {
	## provider is multi ( GNTP )
        foreach my $k (keys %{$notify->{$provider}}) {
	    ## for now - we will just return 1 if any of them are enabled --- the NotifySUB of the provider will handle the multiple values
	    return 1 if (ref $notify->{$provider}->{$k} && $notify->{$provider}->{$k}->{'enabled'}  &&  $notify->{$provider}->{$k}->{$push_type});
	}
	## provider is non-multi
	return 1 if ( ( $notify->{$provider}->{'enabled'} ) && ( $notify->{$provider}->{$push_type} || $provider =~ /file/));
    }
    
    return 0;
}

sub ProcessStart() {
    my ($xmlref,$db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year,$ip) = @_;
    my $xml =  XMLout($xmlref);
    my $sth = $dbh->prepare("insert into processed (session_id,ip_address,title,platform,user,orig_title,orig_title_ep,genre,episode,season,summary,rating,year,xml) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    $sth->execute($db_key,$ip,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year,$xml) or die("Unable to execute query: $dbh->errstr\n");
    return  $dbh->sqlite_last_insert_rowid();
}

sub LocateIP() {
    ## locate IP by machineIdentifier in log file -- hoping this will be part of the API at some point
    ##  * added ratingKey -- sometimes the DirectPlay on LAN is missing the standated GET I am expecting..
    ##  ** I think it's due when the IP is in the allowedNetworks
    ## * modified to read file backwards -- if people use custom logs - they can be way to large..

    my $href = shift;
    
    if ($log_client_ip && ref $href) {
	# two logs should be enough.. shouldn't rotate more than once
	my @logs = ($server_log,
		    $server_log . '.1',
	    );
	my $max_lines = 10000; # seems like a lot.. but it's not
	
	foreach my $log (@logs) {
	    if (-f $log) {
		my $match;
		
		my $bw = File::ReadBackwards->new( $log ) or die "can't read 'log_file' $!" ;
		
		my $ip;
		my $find = $href->{'machineIdentifier'};
		my $item = $href->{'ratingKey'};
		
		my $d_out = "Locating IP for $href->{ratingKey}:$href->{'machineIdentifier'} [$href->{'user'}:$href->{'title'}] from $log... ";
		my $count = 0;
		while( defined( my $log_line = $bw->readline ) && !$ip) {
		    last if ($count > $max_lines);
		    $count++;

		    if ($log_line =~ /(GET|HEAD]).*[^\d]$item.*(X-Plex-Client-Identifier|session)=$find.*\s+\[(.*)\:\d+\]/i) {
			$ip = $3;
			$match = $log_line . " [ by $2:$find + item:$item]";
		    }
		    elsif ($log_line =~ /(GET|HEAD).*(X-Plex-Client-Identifier|session)=$find.*\s+\[(.*)\:\d+\]/i) {
			$ip = $3;
			$match = $log_line . " [ by $2:$find only]";
		    }
		}
		
		$d_out .= $ip if $ip;
		$d_out .= "NO IP found ($count lines searched)" if !$ip;
		&DebugLog($d_out);
		&DebugLog("$ip log match (line $count): $match") if $ip;
		
		## this is a failsafe [fallback] way to get IP - it might be incorrect if multiple people are view the item at the same time
		##  fallback seems to work sometimes -- but depending if the video was started ~10 seconds before the run of this, the log line isn't logged yet. We need to sleep for a couple seconds
		if (!$ip) {
		    my $sleep = 5;
		    &DebugLog("Trying fallback mode for IP match (sleeping $sleep seconds before reloading log $log");
		    sleep 5; # we will sleep 5 seconds before searching log again -- and load the log file again.
		    $bw = File::ReadBackwards->new( $log ) or die "can't read 'log_file' $!" ;
		    $count = 0;
		    my $find = $item;
		    my $d_out = "Locating IP for $href->{ratingKey} [$href->{'user'}:$href->{'title'}] from $log... ";
		    $d_out = "Locating IP for item $href->{ratingKey} from $log... ";
		    while( defined( my $log_line = $bw->readline ) && !$ip) {
			last if ($count > $max_lines);
			$count++;
			
			if ($log_line =~ /GET.*playing.*ratingKey=$find[^\d].*\s+\[(.*)\:\d+\]/) { 
			    $ip = $1; 
			    $match = $log_line . "[ fallback match 1 ]";
			}
			elsif ($log_line =~ /GET.*\/$find\?checkFiles.*\s+\[(.*)\:\d+\]/) { 
			    $ip = $1; 
			    $match = $log_line . "[ fallback match 2 ]";
			}
			elsif ($log_line =~ /GET.*[^\d]$find[^\d].*\s+\[(.*)\:\d+\]/) { 
			    $ip = $1; 
			    $match = $log_line . "[ fallback match 3 ]";
			}
			## best line to match (but not always available at start)
			# Request: GET /:/timeline?time=0&duration=1399200&state=playing&ratingKey=87959&key=%2Flibrary%2Fmetadata%2F87959&containerKey=http%3A%2F%2F10.0.0.5%3A32400%2Flibrary%2Fmetadata%2F87958%2Fchildren [10.0.0.5:3283] (469 live)
			
			## option 2 (called before starting -- maybe)
			# Request: GET /library/metadata/87959?checkFiles=1 [10.0.0.5:43515] (469 live)
			
			# worst of all three -- this is just a view
			# Request: GET /photo/:/transcode?url=http%3A%2F%2F127.0.0.1%3A32400%2Flibrary%2Fmetadata%2F87959%2Fthumb%2F1377723508&width=214&height=306&format=jpeg&background=363636 [10.0.0.5:61215] (469 live)

		    }
		    $d_out .= $ip if $ip;
		    $d_out .= "NO IP found ($count lines searched)" if !$ip;
		    &DebugLog($d_out);
		    &DebugLog("$ip log match (line $count): $match") if $ip;
		}
		return $ip if $ip;
	    }
	}
    }
}

sub ProcessUpdate() {
    my ($xmlref,$db_key,$ip_address) = @_;
    my ($sess,$key) = split("_",$db_key);

    
    #print "processing update";
    #print Dumper($xmlref);

    my $xml =  XMLout($xmlref);
    
    ## multiple checks to verify the xml we update is valid
    return if !$xmlref->{'title'}; ## xml must have title
    return if !$xmlref->{'key'}; ## xml ref must have key
    return if $xml !~ /$key/i; ## xml must contain key

    my ($cmd,$sth);
	my $state_change=0;

    if ($db_key) {
	
	## get paused status -- needed for real time watched
	my $extra ='';
	my $p_counter = 0;

	my $state =  $xmlref->{Player}->{'state'} if $xmlref->{Player}->{state};
	$cmd = "select paused,paused_counter from processed where session_id = ?";
	$sth = $dbh->prepare($cmd);
	$sth->execute($db_key) or die("Unable to execute query: $dbh->errstr\n");
	my $p = $sth->fetchrow_hashref;
	
	$p_counter = $p->{'paused_counter'} if $p->{'paused_counter'};
	my $p_epoch = $p->{'paused'} if $p->{'paused'};
	my $prev_state = (defined($p_epoch)) ? "paused" : "playing";
	## video is paused: verify DB has the pause epoch set
	print "\n* Video State: $state [prev: $prev_state]\n" if ($debug && defined($state));
	if ($state && ($prev_state !~ /$state/i)) {
	    $state_change=1;
	}
	
	my $now = time();
	if (defined($state) && $state =~ /paused/i) {
	    #my $sec = $now-$p_epoch;
	    #my $total_sec = $p_counter+$sec;
	    if (!$p_epoch) {
		$extra .= sprintf(",paused = %s",$now);
		printf "* Marking as as Paused on %s [%s]\n",scalar localtime($now),$now if ($debug && defined($state));
	    } else {
		$p_counter += $now-$p_epoch; ## only for display on debug -- do NOT update db with this.
		printf "* Already marked as Paused on %s [%s]\n",scalar localtime($p_epoch),$p_epoch if ($debug && defined($state));
		#$extra .= sprintf(",paused_counter = %s",$total_sec); #update counter
	    }
	} 
	## Video is not paused -- verify DB not paused and update counter
	else {
	    if ($p_epoch) {
		my $sec = $now-$p_epoch;
		$p_counter += $sec;
		$extra .= sprintf(",paused = %s",'NULL'); # set Paused to NULL
		$extra .= sprintf(",paused_counter = %s",$p_counter); #update counter
		printf "* removing Paused state and setting paused counter to %s seconds [this duration %s sec]\n",$p_counter,$sec if $debug;
	    }
	}
	print "* Total Paused duration: " . &durationrr($p_counter) . " [$p_counter seconds]\n" if $p_counter && $debug;
	
	# include IP update if we have it
	$extra .= sprintf(",ip_address = '%s'",$ip_address) if $ip_address;
	
	
	$cmd = sprintf("update processed set xml = ?%s where session_id = ?",$extra);
	$sth = $dbh->prepare($cmd);
	$sth->execute($xml,$db_key) or die("Unable to execute query: $dbh->errstr\n");	
	
    }
    #return  $dbh->sqlite_last_insert_rowid();
    return $state_change;
}
sub ProcessRecentlyAdded() {
    my ($db_key) = @_;
    my $cmd = "select item_id from recently_added where item_id = '$db_key'";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my @row = $sth->fetchrow_array;
    
    if (!$row[0]) {
	$sth = $dbh->prepare("insert into recently_added (item_id) values (?)");
	$sth->execute($db_key) or die("Unable to execute query: $dbh->errstr\n");
    }
}

sub GetSessions() {
    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $url = "$proto://$server:$port/status/sessions";
    
    # Generate our HTTP request.
    my ($userAgent, $request, $response);
    $userAgent = LWP::UserAgent->new();
    
    $userAgent->timeout(20);
    $userAgent->agent($appname);
    $userAgent->env_proxy();
    $request = HTTP::Request->new(GET => &PMSurl($url));
    $response = $userAgent->request($request);

    if ($response->is_success) {
	#my $XML  = $response->decoded_content();
	my $XML  = $response->content();
	
	if ($debug_xml) {
	    print "URL: $url\n";
	    print "===================================XML CUT=================================================\n";
	    print $XML;
	    print "===================================XML END=================================================\n";
	}

	## I might want to encode it before I push it to XMLIN ( it seems it XMLIN wants it encoded )
	#my $string = "Résumé";
	#print decode_utf8($XML.$string);
	#print encode_utf8($XML.$string);

	my $data = XMLin($XML,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
	return $data->{'Video'};
    } else {
	print "\nFailed to get request $url - The result: \n\n";
	#print $response->decoded_content() . "\n\n";
	print $response->content() . "\n\n";
	if ($options{debug}) {	 	
	    print "\n-----------------------------------DEBUG output----------------------------------\n\n";
	    print Dumper($response);
	    print "\n---------------------------------END DEBUG output---------------------------------\n\n";
	}
    	exit(2);	
    }
}

sub PMSToken() {
    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $url = "$proto://$server:$port";
    
    # Generate our HTTP request.
    my ($userAgent, $request, $response);
    $userAgent = LWP::UserAgent->new();
    $userAgent->timeout(10);
    $userAgent->agent($appname);
    $userAgent->env_proxy();
    $request = HTTP::Request->new(GET => $url);
    $response = $userAgent->request($request);
    
    
    if ($response->code == 401) {
	my $token = &myPlexToken();
	return $token;
    }
    return 0;
}


sub getSecPaused() {
    my $db_key = shift;
    if ($db_key) {
	my $cmd = "select paused,paused_counter from processed where session_id = '$db_key'";
	my $sth = $dbh->prepare($cmd);
	$sth->execute or die("Unable to execute query: $dbh->errstr\n");
	my $row = $sth->fetchrow_hashref;
	my $total=0;
	$total=$row->{'paused_counter'} if $row->{'paused_counter'};
	if (defined($row->{'paused'})) {
	    $total += time()-$row->{'paused'};
	}
	$total = 0 if !$total || $total !~ /\d+/;
	return $total;
    }
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

sub GetRecentlyAddedDB() {
    my $info = ();
    my $cmd = "select * from recently_added";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
	$info->{$row_hash->{'item_id'}} = $row_hash;
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

sub SetNotified_RA() {
    my $provider = shift;
    my $id = shift;
    my $status = shift;
    $status = 1 if !$status; ## status = 1 by default (success), 2 = failed - day old.. do not process anymore
    if ($id) {
	my $cmd = "update recently_added set $provider = $status where item_id = '$id'";
	print $cmd . "\n" if ($debug);
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
	{ 'name' => 'paused', 'definition' => 'timestamp',},
	{ 'name' => 'paused_counter', 'definition' => 'INTEGER',},
	{ 'name' => 'xml', 'definition' => 'text',},
	{ 'name' => 'ip_address', 'definition' => 'text',},
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
	    print "Could not upgrade table definitions - Transaction aborted because $@\n";
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
    
    ## future tables..
    
    &DB_ra_table($dbh);  ## verify/create RecentlyAdded table
    
    return $dbh;
}

sub DB_ra_table() {
    ## verify Recnetly Added table
    my $dbh = shift;
    my $dbtable = 'recently_added';
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    #ALTER TABLE Name ADD COLUMN new_column INTEGER DEFAULT 0
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) { }
    else {
        my $cmd = "CREATE TABLE $dbtable (item_id text primary key, time timestamp default (strftime('%s', 'now')) );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
    }
    
    ## Add new columns/indexes on the fly  -- and change definitions
    my @dbcol = (
	{ 'name' => 'debug', 'definition' => 'text',},
	{ 'name' => 'file', 'definition' => 'INTEGER',},
	{ 'name' => 'twitter', 'definition' => 'INTEGER',},
	{ 'name' => 'growl', 'definition' => 'INTEGER',},
	{ 'name' => 'prowl', 'definition' => 'INTEGER',},
	{ 'name' => 'GNTP', 'definition' => 'INTEGER',},
	{ 'name' => 'pushover', 'definition' => 'INTEGER',},
	{ 'name' => 'boxcar', 'definition' => 'INTEGER',},
	
	);
    
    my @dbidx = (
	{ 'name' => 'itemIds', 'table' => 'item_id', },
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
	    print "Could not upgrade table definitions - Transaction aborted because $@\n";
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
}

sub NotifyTwitter() {
    my $provider = 'twitter';

    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }
    
    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    my $url = $alert_options->{'url'} if $alert_options->{'url'};
    $alert = $push_type_titles->{$alert_options->{'push_type'}} . ': ' . $alert if $alert_options->{'push_type'};        
    
    ## trim down alert..
    if (length($alert) > 139) {	
	$alert = substr($alert,0,140);  ## strip down to 140 chars
	if ($alert =~ /(.*)\[.*/g) { $alert = $1; } ## cut at last brackets to clean up a little
    }
    
    ## url can be appended - twitter allows it even if the alert is 140 chars -- well it looks like 115 is max if URL is included..
    my $non_url_alert = $alert;
    if ($url) {
	if (length($alert) > 114) {
	    $alert = substr($alert,0,114);   
	    if ($alert =~ /(.*)\[.*/g) { $alert = $1; } ## cut at last brackets to clean up a little
	}
	$alert .= ' '. $url;   
    }
    
    ## cleanup spaces
    $alert =~ s/\s+$//g; ## trim any spaces from END
    $alert =~ s/^\s+//g; ## trim any spaces from START
    $alert =~ s/\s+/ /g; ## replace multiple spaced with ONE
    
    if ($debug) {
	print "Twitter Alert: $alert\n";
    }
    
    my %tw = %{$notify->{'twitter'}};        
    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key        => $tw{'consumer_key'},
	consumer_secret     => $tw{'consumer_secret'},
	access_token        => $tw{'access_token'},
	access_token_secret => $tw{'access_token_secret'},
	
	);
    
    my $result = eval { $nt->update($alert); };
    
    ## try one more time..
    if ( my $err = $@ ) {
	## my $rl = $nt->rate_limit_status; not useful for writes atm
	# twitter API doesn't publish limits for writes -- we will use this section to try again if they ever do.
	# if ($err->code == 403 && $rl->{'resources'}->{'application'}->{'/application/rate_limit_status'}->{'remaining'} > 1) {
	if ($err->code == 403) {
	    $provider_452->{$provider} = 1;
	    my $msg452 = uc($provider) . " error 403: $alert - (You are over the daily limit for sending Tweets. Please wait a few hours and try again.) -- setting $provider to back off additional notifications";
	    &ConsoleLog($msg452,,1);
	    return 0;
	}
    }
    
    ## if we tried above or error code was not 403 -- continue with error
    if ( my $err = $@ ) {
	#die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
	if ($debug) {
	    warn "HTTP Response Code: ", $err->code, "\n",
	    "HTTP Message......: ", $err->message, "\n",
	    "Twitter error.....: ", $err->error, "\n";
	}
	return 0;
    }

    print uc($provider) . " Notification successfully posted.\n" if $debug;
    return 1;     ## success
}

sub NotifyProwl() {
    ## modified from: https://www.prowlapp.com/static/prowl.pl
    my $provider = 'prowl';

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }
    
    my %prowl = %{$notify->{prowl}};

    
    
    $prowl{'event'} = '';
    $prowl{'event'} = $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};

    $prowl{'notification'} = $alert;
    
    $prowl{'priority'} ||= 0;
    $prowl{'application'} ||= $appname;
    $prowl{'url'} ||= "";
    
    ## allow formatting of appname
    $prowl{'application'} = '{user}' if $prowl{'application'} eq $appname; ## force {user} if people still use $appname in config -- forcing update with the need to modify config.
    my $format = $prowl{'application'};

    if ($format =~ /\{.*\}/) {
	my $regex = join "|", keys %{$alert_options};
	$regex = qr/$regex/;
	$prowl{'application'} =~ s/{($regex)}/$alert_options->{$1}/g;
	$prowl{'application'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
	$prowl{'application'} = $appname if !$prowl{'application'}; ## replace appname if empty
    }

    # URL encode our arguments
    $prowl{'application'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'event'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'notification'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    
    # allow line breaks in message/notification
    $prowl{'notification'} =~ s/\%5Cn/\%0d\%0a/g;
    
    my $providerKeyString = '';
    
    # Generate our HTTP request.
    my ($userAgent, $request, $response, $requestURL);
    $userAgent = LWP::UserAgent->new();
    $userAgent->timeout(20);
    $userAgent->agent($appname);
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
	print uc($provider) . " Notification successfully posted.\n" if $debug;
	return 1;     ## success
    } elsif ($response->code == 401) {
	print STDERR "PROWL - Notification not posted: incorrect API key.\n";
    } else {
	print STDERR "PROWL - Notification not posted: $prowl{'notification'} " . $response->content . "\n";
    }
    
    $provider_452->{$provider} = 1;
    my $msg452 = uc($provider) . " failed: $alert - setting $provider to back off additional notifications\n";
    &ConsoleLog($msg452,,1);
    return 0; # failed
}

sub NotifyPushOver() {
    my $provider = 'pushover';

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }
    
    my %po = %{$notify->{pushover}};    
    my $ua      = LWP::UserAgent->new();
    $ua->timeout(20);
    $po{'message'} = $alert;
    	    
    ## PushOver title is AppName by default. If there is a real title for push type, It's 'AppName: push_type'

    ## allow formatting of appname
    $po{'title'} = '{user}' if $po{'title'} eq $appname; ## force {user} if people still use $appname in config -- forcing update with the need to modify config.
    my $format = $po{'title'};

    if ($format =~ /\{.*\}/) {
	my $regex = join "|", keys %{$alert_options};
	$regex = qr/$regex/;
	$po{'title'} =~ s/{($regex)}/$alert_options->{$1}/g;
	$po{'title'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
	$po{'title'} = $appname if !$po{'title'}; ## replace appname if empty
    }
    $po{'title'} .= ': ' . $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};    
    
    
    my $response = $ua->post( "https://api.pushover.net/1/messages.json", [
				  "token" => $po{'token'},
				  "user" => $po{'user'},
				  "sound" => $po{'sound'},
				  "title" => $po{'title'},
				  "message" => $po{'message'},
			      ]);
    my $content  = $response->decoded_content();


    if ($content !~ /\"status\":1/) {
	print STDERR "Failed to post Pushover notification -- $po{'message'} result:$content\n";
	$provider_452->{$provider} = 1;
	my $msg452 = uc($provider) . " failed: $alert -  setting $provider to back off additional notifications\n";
	&ConsoleLog($msg452,,1);

	return 0;
    } 
    
    print uc($provider) . " Notification successfully posted.\n" if $debug;
    return 1;     ## success
}

sub NotifyBoxcar() {
    my $provider = 'boxcar';
    ## this will try to notifiy via box car 
    # It will try to subscribe to the plexWatch service on boxcar if we get a 401 and resend the notification

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }

    my %bc = %{$notify->{boxcar}};    
    $bc{'message'} = $alert;
    
    ## BoxCars title [from name] is set in config.pl. If there is a real title for push type, It's 'From: push_type_title'

    ## allow formatting of appname (boxcar it's the 'from' key)
    $bc{'from'} = '{user}' if $bc{'from'} eq $appname; ## force {user} if people still use $appname in config -- forcing update with the need to modify config.
    my $format = $bc{'from'};
    if ($format =~ /\{.*\}/) {
	### replacemnt templates with variables
	my $regex = join "|", keys %{$alert_options};
	$regex = qr/$regex/;
	$bc{'from'} =~ s/{($regex)}/$alert_options->{$1}/g;
	$bc{'from'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
	$bc{'from'} = $appname if !$bc{'from'}; ## replace appname if empty
    }
    
    $bc{'from'} .= ': ' . $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};    
    
    if (!$bc{'email'}) {
	my $msg = "FAIL: Please specify and email address for boxcar in config.pl";
	&ConsoleLog($msg);
    } else {
        my $response = &NotifyBoxcarPOST(\%bc);
	if ($response->is_success) {
	    print uc($provider) . " Notification successfully posted.\n" if $debug;
	    return 1;
	}

	if ($response->{'_rc'} == 401) {
	    my $ua      = LWP::UserAgent->new();
	    $ua->timeout(20);
	    my $msg = "$bc{'email'} is not subscribed to plexWatch service... trying to subscribe now";
	    &ConsoleLog($msg);
	    my $url = 'http://boxcar.io/devices/providers/'. $bc{'provider_key'} .'/notifications/subscribe';
	    my $response = $ua->post( $url, [
					  "email" => $bc{'email'},#
				      ]);
	    if (!$response->is_success) {
		my $msg = "$bc{'email'} subscription to plexWatch service failed. Is $bc{'email'} email registered to your boxcar account?";
		&ConsoleLog($msg);
	    } else {
		## try notification again now that we are subscribed
		my $msg = "$bc{'email'} is now subscribed to plexWatch service. Trying to send notification again.";
		&ConsoleLog($msg);
		$response = &NotifyBoxcarPOST(\%bc);
		if ($response->is_success) {
		    print uc($provider) . " Notification successfully posted.\n" if $debug;
		    return 1;
		}
	    }
	}
    }

    $provider_452->{$provider} = 1;
    my $msg452 = uc($provider) . " failed: $alert - setting $provider to back off additional notifications\n";
    &ConsoleLog($msg452,,1);
    return 0;
}




sub NotifyGNTP() {
    my $provider = 'GNTP';
    ## this will try to notifiy via box car 
    # It will try to subscribe to the plexWatch service on boxcar if we get a 401 and resend the notification

    #my $alert = shift;
    my $info = shift;
    my $alert_options = shift;

    ## TODO -- make the 452 per multi provider
    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }
    
    my ($success,$alert);
    foreach my $k (keys %{$notify->{$provider}}) {
	($alert) = &formatAlert($info,$provider,$k);
	
	## the ProviderEnabled check before doesn't work for multi (i.e. GNTP for now) we will have to verify this provider is actually enabled in the foreach..
	my $push_type = $alert_options->{'push_type'};
	if (ref $notify->{$provider}->{$k} && $notify->{$provider}->{$k}->{'enabled'}  &&  $notify->{$provider}->{$k}->{$push_type}) {
	    print "$provider key:$k enabled for this $alert_options->{'push_type'}\n" if $debug;
	} else {
	    print "$provider key:$k NOT enabled for this $alert_options->{'push_type'} - skipping\n" if $debug;
	    next;
	}
	
	my %gntp = %{$notify->{GNTP}->{$k}};    
	$gntp{'message'} = $alert;

	$gntp{'title'} = '{user}' if !$gntp{'title'};	
	
	## allow formatting of appname
	
	if ($gntp{'title'} =~ /\{.*\}/) {
	    my $regex = join "|", keys %{$alert_options};
	    $regex = qr/$regex/;
	    $gntp{'title'} =~ s/{($regex)}/$alert_options->{$1}/g;
	    $gntp{'title'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
	    $gntp{'title'} = $appname if !$gntp{'title'}; ## replace appname if empty
	}
	
	$gntp{'title'} .= ' ' . $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};    



	if ($gntp{'sticky'} =~ /1/) {
	    $gntp{'sticky'} = 'true'; 
	} else {
	    $gntp{'sticky'} = 'false'; 
	}
	
	if (!$gntp{'server'} || !$gntp{'port'} ) {
	    my $msg = "FAIL: Please specify a server and port for $provider [$k] in config.pl";
	    &ConsoleLog($msg,,1);
	} else {
	    
	    my $growl = Growl::GNTP->new(
		AppName => $gntp{'application'},
		PeerHost => $gntp{'server'},
		PeerPort => $gntp{'port'},
		Password => $gntp{'password'},
		Timeout  =>  $gntp{'timeout'},
		AppIcon => $gntp{'icon_url'},
		);
	    
	    eval { 
		$growl->register(
		    [
		     { Name => 'push_watching',
		       DisplayName => 'push_watching',
		       Enabled     => 'True',
		       Icon => $gntp{'icon_url'},
		     },
		     
		     { Name => 'push_watched',
		       DisplayName => 'push_watched',
		       Enabled     => 'True',
		       Icon => $gntp{'icon_url'},
		     },
		     
		     { Name => 'push_recentlyadded',
		       DisplayName => 'push_recentlyadded',
		       Enabled     => 'True',
		       Icon => $gntp{'icon_url'},
		     },

		     { Name => 'push_resumed',
		       DisplayName => 'push_resumed',
		       Enabled     => 'True',
		       Icon => $gntp{'icon_url'},
		     },

		     { Name => 'push_paused',
		       DisplayName => 'push_paused',
		       Enabled     => 'True',
		       Icon => $gntp{'icon_url'},
		     },
		     
		    ]);
	    };
	    
	    if (!$@) {
		$growl->notify(
		    Priotity => 0,
		    Sticky => 'false',
		    Name => $alert_options->{'push_type'},
		    Title => $gntp{'title'},
		    Message => $alert,
		    ID => time(),
		    Icon => $gntp{'icon_url'},
		    Sticky => $gntp{'sticky'},
		    );
		
		print uc($provider) . " Notification successfully posted.\n" if $debug;
		#return 1;     ## success
		$success++; ## increment success -- can't return as we might have multiple destinations
	    }
	}
	
    }

    return 1 if $success;

    ## this could be moved above scope to 452 specific GNTP dest that failed -- need to look into RecentlyAdded code to see how it affect that.
    $provider_452->{$provider} = 1;
    my $msg452 = uc($provider) . " failed: $alert - setting $provider to back off additional notifications\n";
    &ConsoleLog($msg452,,1);
    return 0;
    
}



sub NotifyEMAIL() {
    my $provider = 'EMAIL';
    ## this will try to notifiy via box car 
    # It will try to subscribe to the plexWatch service on boxcar if we get a 401 and resend the notification

    #my $alert = shift;
    my $info = shift;
    my $alert_options = shift;

    ## TODO -- make the 452 per multi provider
    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }
    
    my ($success,$alert,$error);
    foreach my $k (keys %{$notify->{$provider}}) {
	($alert) = &formatAlert($info,$provider,$k);
	## the ProviderEnabled check before doesn't work for multi 
	# (i.e. GNTP & EMAIL for now) we will have to verify this provider is actually enabled in the foreach..
	my $push_type = $alert_options->{'push_type'};
	if (ref $notify->{$provider}->{$k} && $notify->{$provider}->{$k}->{'enabled'}  &&  $notify->{$provider}->{$k}->{$push_type}) {
	    print "$provider key:$k enabled for this $alert_options->{'push_type'}\n" if $debug;
	} else {
	    print "$provider key:$k NOT enabled for this $alert_options->{'push_type'} - skipping\n" if $debug;
	    next;
	}
	
	my %email = %{$notify->{EMAIL}->{$k}};    
	$email{'message'} = $alert;

	$email{'subject'} = '{user}' if !$email{'subject'};	
	
	## allow formatting of appname
	
	$email{'subject'} =~ s/{push_title}/$push_type_titles->{$alert_options->{'push_type'}}/g if $alert_options->{'push_type'};  
	if ($email{'subject'} =~ /\{.*\}/) {
	    my $regex = join "|", keys %{$alert_options};
	    $regex = qr/$regex/;
	    $email{'subject'} =~ s/{($regex)}/$alert_options->{$1}/g;
	    $email{'subject'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
	    $email{'subject'} = $appname if !$email{'subject'}; ## replace appname if empty
	    $email{'subject'} = $email{'subject'} . ' ';
	}
	
	
	#$email{'subject'} .= $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};    


	if (!$email{'server'} || !$email{'port'} || !$email{'from'} || !$email{'to'} ) {
	    my $msg = "FAIL: Please specify a server, port, to and from address for $provider [$k] in config.pl";
	    &DebugLog($msg,1);
	} else {
	    
	    
	    # Configure smtp server - required one time only

	    eval {
		my $mailer;
		$mailer = new Net::SMTP::TLS(
		    $email{'server'},
		    ( $email{'server'} ? (Hello => $email{'server'}) : () ),
		    ( $email{'port'} ? (Port => $email{'port'}) : () ),
		    ( $email{'username'} ? (User => $email{'username'}) : () ),
		    ( $email{'password'} ? (Password => $email{'password'}) : () ),
		    ( $email{enable_tls}  ? () : (NoTLS => 1) ) ,
		    );
		
		
		$mailer->mail($email{'from'});
		$mailer->to($email{'to'});
		$mailer->data;
		$mailer->datasend("To: $email{'to'}\r\n");
		$mailer->datasend("From: $email{'from'}\r\n");
		$mailer->datasend("Subject: $email{'subject'}\r\n");
		$mailer->datasend("X-Mailer: plexWatch\r\n");
		$mailer->datasend($alert);
		$mailer->dataend;
		$mailer->quit;
	    };
	    if ($@) {
		$error .= $@;
		my $d_out =  uc($provider) . " failed " . substr($alert,0,100);
		&DebugLog($d_out,1);
		$d_out = uc($provider) . " error: $error";
		&DebugLog($d_out,1);
	    } else {
		$success++; ## increment success -- can't return as we might have multiple destinations (however it one works, they all work--TODO tofix)
		my $d_out = uc($provider) . " Notification successfully posted to . " . $email{'to'} . "\n";
		&DebugLog($d_out);
	    }
	    
	}
	
    }
    
    return 1 if $success;
    
    ## this could be moved above scope to 452 specific GNTP dest that failed -- need to look into RecentlyAdded code to see how it affect that.
    $provider_452->{$provider} = 1;
    my $msg452 = uc($provider) . " failed: - setting $provider to back off additional notifications";
    &DebugLog($msg452,1);
    #&ConsoleLog($msg452,,1);
    return 0;
    
}


sub NotifyBoxcarPOST() {
    ## the actual post to boxcar
    my %bc = %{$_[0]};
    
    my $ua      = LWP::UserAgent->new();
    $ua->timeout(20);
    my $url = 'http://boxcar.io/devices/providers/'. $bc{'provider_key'} .'/notifications';
    my $response = $ua->post( $url, [
				  'secret'  => $bc{'provider_secret'},
				  "email" => $bc{'email'},
				  'notification[from_remote_service_id]' => time, # Just a unique placeholder
				  "notification[from_screen_name]" => $bc{'from'},
				  "notification[message]" => $bc{'message'},
				  'notification[icon_url]' => $bc{'icon_url'},
			      ]);
    return $response;
}

sub NotifyGrowl() { 
    my $provider = 'growl';

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;
    my $extra_cmd = '';

    if ($provider_452->{$provider}) {
	if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
	return 0;
    }
    
    my %growl = %{$notify->{growl}};    
    
    $growl{'title'} = $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};    
    $extra_cmd = "$growl{'title'}" if $growl{'title'};
    
    if (!-f  $growl{'script'} ) {
	$provider_452->{$provider} = 1;
	print uc($provider) . " failed $alert: setting $provider to back off additional notifications\n";
	print STDERR "\n$growl{'script'} does not exists\n";
	return 0;
    } else {
	system( $growl{'script'}, "-n", $growl{'application'}, "--image", $growl{'icon'}, "-m", $alert, $extra_cmd); 
	print uc($provider) . " Notification successfully posted.\n" if $debug;
	return 1; ## need better error checking here -- no mac, so I can't test it.
    }
}

sub consoletxt() {
    ## remove line breaks and none ascii
    my $console = shift;
    $console =~ s/\n\n/\n/g;
    $console =~ s/\n/,/g;
    $console =~ s/,$//; # get rid of last comma
#    $console =~ s/[^[:ascii:]]+//g;  Now UTF8
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
    open($script_fh, '<', $0)
	or die("Unable to open script source: $!\n");
    my $max_wait = 30; ## wait 60 (sleep 2) seconds before exiting..
    my $count = 0;
    while (!flock($script_fh, LOCK_EX|LOCK_NB)) {
	#unless (flock($script_fh, LOCK_EX|LOCK_NB)) {
	print "$0 is already running. waiting.\n" if $debug;
	$count++;
	sleep 2;
	if ($count > $max_wait) { 
	    print "CRITICAL: max wait of $max_wait seconds reached.. other running $0?\n";
	    exit(2);
	}
    }
}

sub FriendlyName() {
    my $user = shift;
    my $device = shift;
    
    my $orig_user = $user;
    $user = $user_display->{$user} if $user_display->{$user};
    if ($device && $user_display->{$orig_user.'+'.$device} ) {
	$user = $user_display->{$orig_user.'+'.$device};
    }
    return ($user,$orig_user);
}

sub durationrr() {
    my $sec = shift;
    return duration(0) if !$sec;
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
    my $paused = shift;
    my $duration = shift; ## special case to group start/stops
    $paused = 0 if !$paused;

    ## start time is in xml

    
    my $vid = XMLin($hash,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);


    ## paused or playing? stopped is forced and required from ntype
    my $state = 'unknown';
    if ($ntype =~ /watched|stop/) {
	$state = 'stopped';
    } else {
	$state =  $vid->{Player}->{'state'} if $vid->{Player}->{state};
    }

    
    my $ma_id = '';
    $ma_id = $vid->{Player}->{'machineIdentifier'} if $vid->{Player}->{'machineIdentifier'};
    my $ratingKey = $vid->{'ratingKey'} if $vid->{'ratingKey'};
    
    ## how many minutes in are we? TODO - cleanup when < 90 -- formatting is a bit odd with [0 seconds in]
    my $viewOffset = 0;
    if ($vid->{viewOffset}) {
	## if viewOffset is less than 90 seconds.. lets consider this 0 -- quick hack to fix initial start
	if ($vid->{viewOffset}/1000 < 90) {
	    $viewOffset = &durationrr(0);
	} else {
	    $viewOffset =  &durationrr($vid->{viewOffset}/1000) if $vid->{viewOffset};
	}
    }
    
    ## Transcoded Info
    my $isTranscoded = 0;
    my $transInfo; ## container used for transcoded information - not in use yet
    my $streamType = 'D';
    if (ref $vid->{TranscodeSession}) {
	$isTranscoded = 1;
	$transInfo = $vid->{TranscodeSession};	
	$streamType = 'T';
    }

    ## Time left Info
    my $time_left = 'unknown';
    if ($vid->{duration} && $vid->{viewOffset}) {
	$time_left = &durationrr(($vid->{duration}/1000)-($vid->{viewOffset}/1000));
    }

    ## Start/Stop Time
    my $start_time = '';
    my $stop_time = '';
    my $time = $start_epoch;
    $start_time = localtime($start_epoch)  if $start_epoch;
    $stop_time = localtime($stop_epoch)  if $stop_epoch;
    
    ## Duration Watched
    my $duration_raw;

    if (!$duration) {
	if ($time && $stop_epoch) {
	    $duration = $stop_epoch-$time;
	} else {
	    $duration = time()-$time;
	}
    }
    # set original duration
    $duration_raw = $duration;
    
    #exclude paused time
    $duration = $duration-$paused if !$count_paused;
    
    $duration = &durationrr($duration);

    ## Percent complete -- this is correct ongoing in verison 0.0.18
    my $percent_complete;
    if ( ($vid->{viewOffset} && $vid->{duration}) && $vid->{viewOffset} > 0 && $vid->{duration} > 0) {
	$percent_complete = sprintf("%.0f",($vid->{viewOffset}/$vid->{duration})*100);
	if ($percent_complete >= 90) {	$percent_complete = 100;    } 
    }
    ## version prior to 0.0.18 -- we will have to use duration watched to figure out percent
    ## not the best, but if percent complete is < 10 -- let's go with duration watched (including paused) vs duration of the video
    
    #if (!$percent_complete || $percent_complete < 10) { # no clue why I had < 10%.. lame
    if (!$percent_complete || $percent_complete == 0) {
	$percent_complete = 0;
	# $duration_raw is correct as we didn't have paused seconds yet. 
	# When we had pasued seconds, the percent_complete would have already applied above
	if ( ($vid->{duration} && $vid->{duration} > 0) && ($duration_raw && $duration_raw > 0) )  {
	    $percent_complete = sprintf("%.0f",($duration_raw/($vid->{duration}/1000))*100);
	    if ($percent_complete >= 90) {	$percent_complete = 100;    } 
	}
    }
    $percent_complete = 0 if !$percent_complete;
    
    my ($rating,$year,$summary,$extra_title,$genre,$platform,$title,$episode,$season);    
    $rating = $year = $summary = $extra_title = $genre = $platform = $title = $episode = $season = '';
    
    $title = $vid->{title};
    
    ## Platform title (client device)
    ## prefer title over platform if exists ( seem to have the exact same info of platform with useful extras )
    if ($vid->{Player}->{title}) {	$platform =  $vid->{Player}->{title};    }
    elsif ($vid->{Player}->{platform}) {	$platform = $vid->{Player}->{platform};    }
    
    ## length of the video
    my $length;
    $length = sprintf("%.0f",$vid->{duration}/1000) if $vid->{duration};
    $length = &durationrr($length);
    
    my $orig_user = (split('\@',$vid->{User}->{title}))[0]     if $vid->{User}->{title};
    if (!$orig_user) {	$orig_user = 'Local';        }
    
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
	$episode = $vid->{index} if $vid->{index};
	$season = $vid->{parentIndex} if $vid->{parentIndex};
	if ($episode =~ /\d+/ && $episode < 10) { $episode = 0 . $episode};
	if ($season =~ /\d+/ && $season < 10) { $season = 0 . $season};
	$title .= ' - s'.$season.'e'.$episode if ($season =~ /\d+/ && $episode =~ /\d+/);
    }
    
    ## formatting now allows user to include year, rating, etc...
    #if ($vid->{'type'} =~ /movie/) {
    #	## to fix.. multiple genres
    #	#if (defined($vid->{Genre})) {	    $title .= ' ['.$vid->{Genre}->{tag}.']';	}
    #	$title .= ' ['.$year.']';
    #	$title .= ' ['.$rating.']';
    #   }
    
    my ($user,$tmp) = &FriendlyName($orig_user,$platform);

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
	'progress' => $viewOffset,
	'percent_complete' => $percent_complete,
	'time_left' => $time_left,
	'viewOffset' => $vid->{viewOffset},
	'state' => $state,
	'transcoded' => $isTranscoded,
	'streamtype' => $streamType,
	'transInfo' => $transInfo,	
	'machineIdentifier' => $ma_id,
	'ratingKey' => $ratingKey,
    };
    
    return $info;
}

sub RunTestNotify() {
    my $ntype = 'start'; ## default
    
    my $map ={
	'start' =>  'start',
	'watching' =>  'start-watching',
	'watched' =>  'stop-watched',
	'stop' =>  'stop',
	'pause' =>  'push_paused',
	'resumed' =>  'push_resumed',
	#'new' =>  'push_recentlyadded',
	'recent' =>  'push_recentlyadded',
    };
    
    if (!$options{test_notify} || !$map->{lc($options{test_notify})}) {
	print "Usage: $0 --test_notify=[option]\n\n";
	print "\t[option]\n";
	print "\t" . join("\n\t", sort keys %{$map});
	print "\n\n";
	exit;
    }

    $ntype = 'start' if $options{test_notify} =~ /start/i;
    $ntype = 'start-watching' if $options{test_notify} =~ /watching/i;
    $ntype = 'stop-watched' if $options{test_notify} =~ /watched/i;
    $ntype = 'stop' if $options{test_notify} =~ /stop/i;
    $ntype = 'push_paused' if $options{test_notify} =~ /pause/i;
    $ntype = 'push_resumed' if $options{test_notify} =~ /resumed/i;
    $ntype = 'push_recentlyadded' if $options{test_notify} =~ /recent|new/i;


    if ($ntype =~ /push_recentlyadded/) {
	my $alerts = ();
	$alerts->{'test'}->{'alert'} = $push_type_titles->{$ntype} .' test recently added alert';
	$alerts->{'test'}->{'alert_short'} = $push_type_titles->{$ntype} .'test recently added alert (short version)';
	$alerts->{'test'}->{'item_id'} = 'test_item_id';
	$alerts->{'test'}->{'debug_done'} = 'testing alert already done';
	$alerts->{'test'}->{'alert_url'} = 'https://github.com/ljunkie/plexWatch';
	&ProcessRAalerts($alerts,1);
    } else {
	$format_options->{'ntype'} = $ntype;
	my $test_info = &GetTestNotify($ntype);
	## notify if we have a valid DB results
	if ($test_info) {
	    foreach my $k (keys %{$test_info}) {
		my $start_epoch = $test_info->{$k}->{time} if $test_info->{$k}->{time}; ## DB only
		my $stop_epoch = $test_info->{$k}->{stopped} if $test_info->{$k}->{stopped}; ## DB only
		my $info = &info_from_xml($test_info->{$k}->{'xml'},$ntype,$start_epoch,$stop_epoch,0);
		$info->{'ip_address'} = $test_info->{$k}->{ip_address};
		&Notify($info);
		## nothing to set as notified - this is a test
	    }
	} 
	## notify the default format if there is not DB log yet.
	else {
	    &Notify($format_options);
	    ## nothing to set as notified - this is a test
	}
    }
    ## test notify -- exit 
    exit;
}


sub twittime() {
    ## twitters way of showing the date/time
    my $epoch = shift;
    my $date = (strftime "%I:%M%p %d %b %y", localtime($epoch));
    $date =~ s/^0//;
    return $date;
}

sub rrtime() {
    ## my way of showing the date/time
    my $epoch = shift;
    my $date = (strftime "%I:%M%p - %a %b ", localtime($epoch)) . suffer(strftime "%e", localtime($epoch)) . (strftime " %Y", localtime($epoch));
    $date =~ s/^0//;
    return $date;
}

sub suffer {
    ## day suffix (st, nd, rd, th)
    local $_ = shift;
    return $_ . (/(?<!1)([123])$/ ? (qw(- st nd rd))[$1] : 'th');
}

sub ParseDataItem() {
    my $data = shift;
    my $info = $data; ## fallback

    if ($data->{'type'} =~ /movie/i || $data->{'type'} =~ /show/ || $data->{'type'} =~ /episode/) {
	$info = ();    	
	$info->{'originallyAvailableAt'} = $data->{'originallyAvailableAt'};
	$info->{'titleSort'} = $data->{'titleSort'};
	$info->{'contentRating'} = $data->{'contentRating'};
	$info->{'thumb'} = $data->{'thumb'};
	$info->{'art'} = $data->{'art'};
	$info->{'videoResolution'} = $data->{'Media'}->{'videoResolution'};
	$info->{'videoCodec'} = $data->{'Media'}->{'videoCodec'};
	$info->{'audioCodec'} = $data->{'Media'}->{'audioCodec'};
	$info->{'aspectRatio'} = $data->{'Media'}->{'aspectRatio'};
	$info->{'audioChannels'} = $data->{'Media'}->{'audioChannels'};
	$info->{'summary'} = $data->{'summary'};
	$info->{'addedAt'} = $data->{'addedAt'};
	$info->{'updatedAt'} = $data->{'updatedAt'};
	$info->{'duration'} = $data->{'duration'};
	$info->{'tagline'} = $data->{'tagline'};
	$info->{'title'} = $data->{'title'};
	$info->{'year'} = $data->{'year'};
	
	$info->{'imdb_title'} = $data->{'title'};
	$info->{'imdb_title'} .= ' ' . $data->{'year'} if $data->{'year'};
    }
    if ($data->{'type'} =~ /show/ || $data->{'type'} =~ /episode/) {
	$info->{'episode'} = $data->{index};
	$info->{'season'} = $data->{parentIndex};
	if ($info->{'episode'} < 10) { $info->{'episode'} = 0 . $info->{'episode'};}
	if ($info->{'season'} < 10) { $info->{'season'} = 0 . $info->{'season'}; }
	$info->{'title'} = $data->{'grandparentTitle'} . ': '.  $data->{'title'} . ' s'.$info->{'season'} .'e'. $info->{'episode'};
	$info->{'imdb_title'} = $data->{'grandparentTitle'} . ': '.  $data->{'title'};
	
    }
    ## everything gets these
    $info->{'type'} = $data->{'type'};
    
    return $info;
}

sub GetSectionsIDs() {
    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $host = "$proto://$server:$port";
    
    my $ua = LWP::UserAgent->new();
    $ua->timeout(20);
    
    my $sections = ();
    my $url = $host . '/library/sections';
    my $response = $ua->get( &PMSurl($url) );
    if ( ! $response->is_success ) {
	print "Failed to get Library Sections from $url\n";
	exit(2);
    } else {
	#my $content  = $response->decoded_content();
	my $content  = $response->content();
	my $data = XMLin($content);
	foreach  my $k (keys %{$data->{'Directory'}}) {
	    $sections->{'raw'}->{$k} = $data->{'Directory'}->{$k};
	    push @{$sections->{'types'}->{$data->{'Directory'}->{$k}->{'type'}}}, $k;
	}
    }
    return $sections;
}

sub GetItemMetadata() {
    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $host = "$proto://$server:$port";
    
    my $ua = LWP::UserAgent->new();
    $ua->timeout(20);

    my $item = shift;
    my $full_uri = shift;
    my $url = $host . '/library/metadata/' . $item;
    if ($full_uri) {
	$url = $host . $item;
    }
    my $sections = ();
    my $response = $ua->get( &PMSurl($url) );
    if ( ! $response->is_success ) {
	if ($options{'debug'}) {
	    print "Failed to get Metadata from from $url\n";
	    print Dumper($response);
	}
	return $response->{'_rc'} if $response->{'_rc'} == 404;
	exit(2);
    } else {
	#my $content  = $response->decoded_content();
	my $content  = $response->content();
	#my $vid = XMLin($hash,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
	#my $data = XMLin($content, KeyAttr => { Role => ''} );
	my $data = XMLin($content);
	return $data->{'Video'} if $data->{'Video'};
    }
}

sub GetRecentlyAdded() {
    my $section = shift; ## array ref &GetRecentlyAdded([5,6,7]);
    my $hkey = shift;    ## array ref &GetRecentlyAdded([5,6,7]);
    
    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $host = "$proto://$server:$port";

    my $ua = LWP::UserAgent->new();
    $ua->timeout(20);

    my $info = ();
    my %result;
    # /library/recentlyAdded <-- all sections
    # /library/sections/6/recentlyAdded <-- specific sectoin
    
    foreach my $section (@$section) {
	my $url = $host . '/library/sections/'.$section.'/recentlyAdded';
	## limit the output to the last 25 added.
	$url .= '?query=c&X-Plex-Container-Start=0&X-Plex-Container-Size=25';
	my $response = $ua->get( &PMSurl($url) );
	if ( ! $response->is_success ) {
	    print "Failed to get Library Sections from $url\n";
	    exit(2);
	} else {
	    #my $content  = $response->decoded_content();
	    my $content  = $response->content();
	    my $data = XMLin($content, ForceArray => ['Video']);
	    ## verify we are recieving what we expect. -- extra output for debugging
	    if (!ref $data && $debug) {
		print " result from $url is not in an expected format\n";
		print "-------------------- CONTENT --------------------\n";
		print $content;
		print "-------------------- END --------------------\n";
		print "-------------------- DUMPER --------------------\n";
		print Dumper($data);
		print "-------------------- END --------------------\n";
		print " result above from $url is not in an expected format\n";
	    }
	    if (ref $data) {
		if ($data->{$hkey}) {
		    if (ref($info)) {
			my $tmp = $data->{$hkey};
			%result = (%$info, %$tmp);
			$info = \%result;
		    } else {
			$info = $data->{$hkey};
		    }
		}
	    }
	}
    }
    return $info;
}

sub urlencode {
    my $s = shift;
    $s =~ s/ /+/g;
    $s =~ s/([^A-Za-z0-9\+-])/sprintf("%%%02X", ord($1))/seg;
    return $s;
}

sub urldecode {
    my $s = shift;
    $s =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
    $s =~ s/\+/ /g;
    return $s;
}

    
sub ProcessRAalerts() {
    my $alerts = shift;
    my $test_notify = shift;
    my $count = 0;
    
    my $ra_done = &GetRecentlyAddedDB() if !$test_notify;  ## only check if done if this is NOT a test
    
    ## used for output
    my $done_keys = {'1' => 'Already Notified',
		     '2' => 'Skipped Notify - to many failures',
		     '3' => 'Skipped Notify - not recent enough to notify',
		     '404' => 'Not Found - No longer found on PMS',
    };
    
    ## $alerts: keys
    # item_id
    # debug_done
    # alert_tag
    # alert_url
    # alert_short
    my %notseen;
    foreach my $k ( sort keys %{$alerts}) {
	$count++;
	my $is_old = 0;
	
	my $alert_options = (); ## container for extra alert info if provider uses it..
	
	## VERIFY notification is for content only recently Added -- RA content is not always recent
	## we will allow for 1 day ( you can set this higher, but shouldn't have to if run on a 5 min cron)
	my $ra_max_age = 1; ## TODO - advanced config options
	if ($k =~ /(\d+)\//) {
	    my $epoch = $1;
	    my $age = time()-$epoch;
	    if ($age > 86400*$ra_max_age) { $is_old = 1; }
	}
	
	my $item_id = $alerts->{$k}->{'item_id'};
	my $debug_done = $alerts->{$k}->{'debug_done'};
	
	## add item to DB -- will ignore insert if already insert.. wish sqlite has upsert
	&ProcessRecentlyAdded($item_id)  if !$test_notify; 
	
	my $push_type = 'push_recentlyadded';
	my $provider;

	$alert_options->{'url'} = $alerts->{$k}->{'alert_url'} if $alerts->{$k}->{'alert_url'};
	$alert_options->{'push_type'} = $push_type;

	
	## 'recently_added' table has columns for each provider -- we will notify and verify each provider has success. 
	## TODO - extend this logic into the normal notifications
	
	## new code - iterate through all providers.. same code block
	
	foreach my $provider (keys %{$notify}) {
	    # provider is globaly enable and provider push type is enable or is file
	    if (&ProviderEnabled($provider,$push_type)) {
	    #if ( ( $notify->{$provider}->{'enabled'} ) && ( $notify->{$provider}->{$push_type} || $provider =~ /file/)) { 
		if ($ra_done->{$item_id}->{$provider}) {
		    printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
		} elsif ($is_old) {
		    &SetNotified_RA($provider,$item_id,3); ## to old - set as old and stop processing
		}
		elsif ($notify_func{$provider}->($alerts->{$k}->{'alert'}, $alert_options)) {
		    &SetNotified_RA($provider,$item_id)   if !$test_notify; 
		} 
		else {
		    if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
			print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
		    }
		}	
	    }
	}
	
    } # end alerts

}

sub GetNotifyfuncs() {
    my %notify_func = (
	prowl => \&NotifyProwl,
	growl => \&NotifyGrowl,	
	pushover => \&NotifyPushOver,
	twitter => \&NotifyTwitter,
	boxcar => \&NotifyBoxcar,
	file => \&NotifyFile,
	GNTP => \&NotifyGNTP,
	EMAIL => \&NotifyEMAIL,
	
	);
    my $error;
    ## this SHOULD never happen if the code is released -- this is just a reminder for whomever is adding a new provider in config.pl
    foreach my $provider (keys %{$notify}) {
	if (!$notify_func{$provider}) {
	    print "$provider: missing a notify function subroutine (did you add a new provider?) -- check 'sub GetNotifyfuncs()' \n";
	    $error = 1;
	}
    }
    die if $error;
    return %notify_func;
}

sub GetPushTitles() {
    my  $push_type_display = ();
    $push_type_display->{'push_watched'} = 'Watched';
    $push_type_display->{'push_watching'} = 'Watching';
    $push_type_display->{'push_paused'} = 'Paused';
    $push_type_display->{'push_resumed'} = 'Resumed';
    $push_type_display->{'push_recentlyadded'} = 'New';
    
    foreach my $type (keys %{$push_type_display}) {
	$push_type_display->{$type} = $push_titles->{$type} if $push_titles->{$type};
    }
    return $push_type_display;
}

sub BackupSQlite() {
    ## this will Auto Backup the sql lite db to $data_dir/db_backups/...
    ## --backup will for a daily backup

    # Override in config.pl with
    
    #$backup_opts = {
    #	'daily' => {
    #	    'enabled' => 0,
    #	    'keep' => 2,
    #	},
    #	'monthly' => {
    #	    'enabled' => 1,
    #	    'keep' => 4,
    #	},
    #	'weekly' => {
    #	    'enabled' => 1,
    #	    'keep' => 4,
    #	},
    #   };
    
    my $path  = $data_dir . '/db_backups';
    if (!-d $path) {
	mkdir($path) or die "Unable to create $path\n";
	chmod(0777, $path) or die "Couldn't chmod $path: $!";
    }
    
    my $backups = {
	'daily' => {
	    'enabled' => 1,
	    'file' => $path . '/plexWatch.daily.bak',
	    'time' => 86400,
	    'keep' => 2,
	},
	'monthly' => {
	    'enabled' => 1,
	    'file' => $path . '/plexWatch.monthly.bak',
	    'time' => 86400*30,
	    'keep' => 4,
	},
	'weekly' => {
	    'enabled' => 1,
	    'file' => $path . '/plexWatch.weekly.bak',
	    'time' => 86400*7,
	    'keep' => 4,
	},
    };

    ## merge options if set in config -- override
    ## also print settings if --debug called with --backup
    foreach my $type (keys %{$backups}) {
	foreach my $key (keys %{$backups->{$type}}) {
	    $backups->{$type}->{$key} = $backup_opts->{$type}->{$key} if defined($backup_opts->{$type}->{$key});
	}


	if ($debug && $options{'backup'}) {
	    print "Backup Type: " .uc($type) . "\n";
	    print "\tenabled: ". $backups->{$type}->{enabled} . "\n";
	    print "\tkeep: ". $backups->{$type}->{keep} . "\n";
	    print "\ttime: ". $backups->{$type}->{time} . ' ('. &durationrr($backups->{$type}->{time}) . ") \n";
	    print "\tfile: ". $backups->{$type}->{file} . "\n\n";
	}
	
    }    
    
    
    foreach my $type (keys %{$backups}) {
	if ($type =~ /daily/ && $options{'backup'}) {
	    print "\n** Daily Backups are not enabled -- but you called --backup, forcing backup now..\n";
	}
	else {
	    next if !$backups->{$type}->{'enabled'};
	}
	
	
	my $do_backup = 1;
	my $file = $backups->{$type}->{'file'};
	$file =~ s/\/\//\//g;
	if (-f $file) {
	    $do_backup =0;
	    my $modtime = (stat($file))[9];
	    my $diff = time()-$modtime;
	    my $max_time = $backups->{$type}->{'time'};
	    
	    my $hum_diff = &durationrr($diff);
	    my $hum_max = &durationrr($max_time);
	    
	    my $extra;
	    if ($options{'backup'} && $type =~ /daily/i) {
		$extra = "Forcing DAILY backups --backup called";
		$do_backup=1;
	    } elsif ($diff > $max_time) {
		$do_backup=1;
		$extra = "Do backup - older than allowed ($hum_diff > $hum_max)";
	    } else {
		$extra = "Backup is current ($hum_diff < $hum_max)" if $debug && $options{'backup'};
	    }
	    printf("\n\t%-10s %-15s %s [%s]\n", uc($type), &durationrr($diff), $file, $extra) if $debug && $options{'backup'};
	    
	} else {
	    print '* ' . uc($type) ." backup not found -- trying now\n";
	}
	if ($do_backup) {
	    my $keep =1;
	    $keep = $backups->{$type}->{'keep'} if $backups->{$type}->{'keep'};
	    
	    if ($keep > 1) {
		print "\t* Rotating files: keep $keep total\n"  if $debug && $options{'backup'};
		for (my $count = $keep-1; $count >= 0; $count--) {
		    my $to = $file .'.'. ($count+1);
		    my $from = $file .'.'. ($count);
		    $from = $file if $count == 0;
		    if (-f $from) { 
			print "\trotating $from -> $to \n"  if $debug && $options{'backup'};
			rename $from, $to; 
		    }
		}
		## Should we clean up older files if they change the keep count to something lower? I think not... (unlink no)
	    } 
	    print "\t* Backup file: $file ... " if $debug || $options{'backup'};
	    $dbh->sqlite_backup_to_file($file);
	    print "DONE\n\n" if $debug || $options{'backup'};
	}
	
    }

    ## exit if --backup was called..
    exit if $options{'backup'};
}

sub myPlexToken() {
    if (!$myPlex_user || !$myPlex_pass) {
	print "* You MUST specify a myPlex_user and myPlex_pass in the config.pl\n";
	print "\n \$myPlex_user = 'your username'\n";
	print " \$myPlex_pass = 'your password'\n\n";
	exit;
    } 
    my $ua = LWP::UserAgent->new();
    $ua->timeout(20);
    $ua->agent($appname);
    $ua->env_proxy();
    
    $ua->default_header('X-Plex-Client-Identifier' => $appname);
    $ua->default_header('Content-Length' => 0);
    
    my $url = 'https://my.plexapp.com/users/sign_in.xml';
    
    my $req = HTTP::Request->new(POST => $url);
    $req->authorization_basic($myPlex_user, $myPlex_pass);
    my $response = $ua->request($req);
    
    
    #print $response->as_string;

    if ($response->is_success) {
	my $data = XMLin($response->decoded_content());
	return $data->{'authenticationToken'} if $data->{'authenticationToken'};
	return $data->{'authentication-token'} if $data->{'authentication-token'};
    } else {
	print $response->as_string;
	die;
    }
}

sub PMSurl() {
    my $url = shift;
    ## append Token if required
    my $j = '?';
    $j = '&' if $url =~ /\?.*\=/;
    $url .= $j . 'X-Plex-Token=' . $PMS_token if $PMS_token;
    return $url;
}



__DATA__

__END__

=head1 NAME 

plexWatch.p - Notify and Log 'Now Playing' and 'Watched' content from a Plex Media Server + 'Recently Added'

=head1 SYNOPSIS


plexWatch.pl [options]

  Options:

   --notify                        Notify any content watched and or stopped [this is default with NO options given]
        --user=...                      limit output to a specific user. Must be exact, case-insensitive
        --exclude_user=...              exclude users - you may specify multiple on the same line. '--notify --exclude_user=user1 --exclude_user=user2'

   --recently_added=show,movie   notify when new movies or shows are added to the plex media server (required: config.pl: push_recentlyadded => 1) 
           * you may specify only one or both on the same line separated by a comma. [--recently_added=show OR --recently_added=movie OR --recently_added=show,movie]

   --stats                         show total time watched / per day breakout included
        --start=...                     limit watched status output to content started AFTER/ON said date/time
        --stop=...                      limit watched status output to content started BEFORE/ON said date/time
        --user=...                      limit output to a specific user. Must be exact, case-insensitive
        --exclude_user=...              exclude users - you may specify multiple on the same line. '--notify --exclude_user=user1 --exclude_user=user2'


   --watched                       print watched content
        --start=...                     limit watched status output to content started AFTER/ON said date/time
        --stop=...                      limit watched status output to content started BEFORE/ON said date/time
        --nogrouping                    will show same title multiple times if user has watched/resumed title on the same day
        --user=...                      limit output to a specific user. Must be exact, case-insensitive
        --exclude_user=...              exclude users - you may specify multiple on the same line. '--notify --exclude_user=user1 --exclude_user=user2'

   --watching                      print content being watched

   --backup                       Force a daily backup of the database. 
                                  * automatic backups are done daily,weekly,monthly - refer to backups section below

   #############################################################################################
    
   --format_options        : list all available formats for notifications and cli output

   --format_start=".."     : modify start notification :: --format_start='{user} watching {title} on {platform}'
 
   --format_stop=".."      : modify stop nottification :: --format_stop='{user} watched {title} on {platform} for {duration}'
 
   --format_watched=".."   : modify cli output for --watched  :: --format_watched='{user} watched {title} on {platform} for {duration}'

   --format_watching=".."  : modify cli output for --watching :: --format_watching='{user} watching {title} on {platform}'

   #############################################################################################
   * Debug Options

   --test_notify=start        [start,stop,recent] - send a test notifcation for a start,stop or recently added event.
   --show_xml                 show xml result from api query
   --version                  what version is this?
   --debug                    hit and miss - not very useful

=head1 OPTIONS

=over 15

=item B<--notify>

This will send you a notification through prowl, pushover, boxcar, growl and/or twitter. It will also log the event to a file and to the database.
This is the default if no options are given.

=item B<--watched>

Print a list of watched content from all users.

=item B<--start>

* only works with --watched

limit watched status output to content started AFTER said date/time

Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

   -start=2013-06-29
   -start="2013-06-29 8:00pm"
   -start="today"
   -start="today at 8:30pm"
   -start="last week"
   -start=... give it a try and see what you can use :)

=item B<--stop>

* only works with --watched

limit watched status output to content started BEFORE said date/time

Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

   -stop=2013-06-29
   -stop="2013-06-29 8:00pm"
   -stop="today"
   -stop="today at 8:30pm"
   -stop="last week"
   -stop=... give it a try and see what you can use :)

=item B<--nogrouping>

* only works with --watched

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


=item B<---user>

* works with --watched and --watching

limit output to a specific user. Must be exact, case-insensitive

=item B<--exclude_user>

limit output to a specific user. Must be exact, case-insensitive

=item B<--watching>

Print a list of content currently being watched

=item B<--stats>

show total watched time and show total watched time per day

=item B<--recently_added>

notify when new movies or shows are added to the plex media server (required: config.pl: push_recentlyadded => 1) 

 --recently_added=movie :: for movies
 --recently_added=show  :: for tv show/episodes

=item B<--show_xml>

Print the XML result from query to the PMS server in regards to what is being watched. Could be useful for troubleshooting..

=item B<--backup>

By default this script will automatically backup the SQlite db to: $data_dir/db_backups/ ( normally: /opt/plexWatch/db_backups/ )

* you can force a Daily backup with --backup

It will keep 2 x Daily , 4 x Weekly  and 4 x Monthly backups. You can modify the backup policy by adding the config lines below to your existin config.pl

$backup_opts = {
        'daily' => {
            'enabled' => 1,
            'keep' => 2,
        },
        'monthly' => {
            'enabled' => 1,
            'keep' => 4,
        },
        'weekly' => {
            'enabled' => 1,
            'keep' => 4,
        },
    };


=item B<--debug>

This can be used. I have not fully set everything for debugging.. so it's not very useful

=back

=head1 DESCRIPTION

This program will Notify and Log 'Now Playing' content from a Plex Media Server

=head1 HELP

nothing to see here.

=cut


