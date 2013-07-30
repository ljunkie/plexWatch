#!/usr/bin/perl -w

my $version = '0.0.15';
my $author_info = <<EOF;
##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified: 2013-07-29 08:00 PST
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

## removed modules
#use WWW::Curl::Easy; #removed -- using LWP
#use URI::Escape; ## now using subroutine

## load config file
my $dirname = dirname(__FILE__);
if (!-e $dirname .'/config.pl') {
    print "\n** missing file $dirname/config.pl. Did you move edit config.pl-dist and copy to config.pl?\n\n";
    exit;
}
do $dirname.'/config.pl';
use vars qw/$data_dir $server $port $appname $user_display $alert_format $notify/; 
if (!$data_dir || !$server || !$port || !$appname || !$alert_format || !$notify) {
    print "config file missing data\n";
    exit;
}
## end

## ONLY Load modules if used
if ($notify->{'twitter'}->{'enabled'}) {
    require Net::Twitter::Lite::WithAPIv1_1;
    require Net::OAuth;
    require Scalar::Util;
    Net::Twitter::Lite::WithAPIv1_1->import(); 
    Net::OAuth->import();
    Scalar::Util->import('blessed');

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
    'progress' => 'progress of video [only available on --watching]',
    'time_left' => 'progress of video [only available on --watching]',
};

if (!-d $data_dir) {
    print "\n** Sorry. Please create your datadir $data_dir\n\n";
    exit;
}

## place holder to back off notifications per provider
my $provider_452 = ();

&CheckLock(); # just make sure we only run one at a time

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
}

my $date = localtime;
my $dbh = &initDB(); ## Initialize sqlite db

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


my %notify_func = &GetNotifyfuncs();

########################################## START MAIN #######################################################



####################################################################
## RECENTLY ADDED 
if ($options{'recently_added'}) {
    my ($want,$hkey);
    if ($options{'recently_added'} =~ /movie/i) {
	$want = 'movie';
	$hkey = 'Video';
    } elsif ($options{'recently_added'} =~ /show|tv/i) {
	$want = 'show';
	$hkey = 'Video';
    }
    
    ## maybe someday.. TODO
    #}    elsif ($options{'recently_added'} =~ /artists|music/i) {
    #	$want = 'artist';
    #	$hkey = 'Directory';
    
    if (!$want) {
	#print "\n 'recently_added' must be: movie, show or artist\n\n";
	print "\n 'recently_added' must be: 'movie' or 'show' \n\n";
	exit;
    }
    
    my $plex_sections = &GetSectionsIDs(); ## allow for multiple sections with the same type (movie, show, etc)
    
    my $info = &GetRecentlyAdded($plex_sections->{'types'}->{$want},$hkey);
    my $alerts = (); # containers to push alerts from oldest -> newest
    
    my %seen;
    foreach my $k (keys %{$info}) {
	$seen{$k} = 1; ## alert seen
	my $item = &ParseDataItem($info->{$k},$want);
	my $res = &RAdataAlert($k,$item,$want);
	$alerts->{$item->{addedAt}.$k} = $res;
    }
    
    ## RA backlog - make sure we have all alerts -- some might has been added previously but notification failed and newer content has purged the results above
    my $ra_done = &GetRecentlyAddedDB();
    my $push_type = 'push_recentlyadded';
    foreach my $provider (keys %{$notify}) {
	next if ( !$notify->{$provider}->{'enabled'} || !$notify->{$provider}->{$push_type}); ## skip provider if not enabled
	foreach my $key (keys %{$ra_done}) {
	    next if $seen{$key}; ## already in alerts hash
	    next if ($ra_done->{$key}->{$provider}); ## provider already notified

	    ## we passed checks -- let's process this old/failed notification
	    my $data = &GetItemMetadata($key,1);
	    
	    ## if result is not a ref 
	    if (!ref($data)) {
		##  maybe we got 404 -- I.E. old/removed video.. set at 404 -> not found
		if ($data =~ /404/) {
		    &SetNotified_RA($provider,$key,404);
		    next;
		}
		## any other results we care about? maybe later
	    }
	    
	    else {
		my $item = &ParseDataItem($data,$want);
		
		## check age of notification. -- allow two days ( we will keep trying to notify for 2 days.. if we keep failing.. we need to skip this)
		my $age = time()-$ra_done->{$key}->{'time'};
		my $ra_max_fail_days = 2; ## TODO: advanced config options?
		if ($age > 86400*$ra_max_fail_days) {
		    ## notification is OLD .. set notify = 2 to exclude from processing
		    my $msg = "Could not notify $provider on [$key] $item->{'title'} for " . &durationrr($age) . " -- setting as old notification/done";
		    &ConsoleLog($msg,1);
		    &SetNotified_RA($provider,$key,2);
		}
		
		next if $data->{'type'} =~ /episode/ && $want !~ /show/; ## next if episode and current task is not a show
		next if $data->{'type'} =~ /movie/ && $want !~ /movie/;  ## next if movie and current task is not a movie
		
		
		if ($alerts->{$item->{addedAt}.$key}) {
		    ## redundant code from above hash %seen 
		    #print "$item->{'title'} is already in current releases... nothing missed\n";
		} else {
		    print "$item->{'title'} is NOT in current releases -- we failed to notify previouly, so trying again\n" if $options{'debug'};
		    my $res = &RAdataAlert($key,$item,$want);
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
    my $want = shift;
    
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
    if ($want eq 'show') {
	$alert = $item->{'title'};
	$alert_short = $item->{'title'};
	$alert .= " [$item->{'contentRating'}]" if $item->{'contentRating'};
	$alert .= " [$item->{'year'}]" if $item->{'year'};
	$alert .=  ' '. sprintf("%.02d",$item->{'duration'}/1000/60) . 'min';
	$alert .= " [$media]" if $media;
	$alert .= " [$add_date]";
	#$twitter = $item->{'title'};
	#$twitter .= " [$item->{'year'}]";
	#$twitter .=  ' '. sprintf("%.02d",$item->{'duration'}/1000/60) . 'min';
	#$twitter .= " [$media]" if $media;
	#$twitter .= " [$add_date]";
	$alert_url .= ' http://www.imdb.com/find?s=tt&q=' . urlencode($item->{'imdb_title'});
    }
    if ($want eq 'movie') {
	$alert = $item->{'title'};
	$alert_short = $item->{'title'};
	$alert .= " [$item->{'contentRating'}]" if $item->{'contentRating'};
	$alert .= " [$item->{'year'}]" if $item->{'year'};
	$alert .=  ' '. sprintf("%.02d",$item->{'duration'}/1000/60) . 'min';
	$alert .= " [$media]" if $media;
	$alert .= " [$add_date]";
	#$twitter = $alert; ## movies are normally short enough.
	$alert_url .= ' http://www.imdb.com/find?s=tt&q=' . urlencode($item->{'imdb_title'});
    }
    
    $result->{'alert'} = 'NEW: '.$alert;
    $result->{'alert_short'} = 'NEW: '.$alert_short;
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
    my %seen_user = ();
    my %stats = ();
    my $ntype = 'watched';
    if (keys %{$is_watched}) {
	print "\n";
	foreach my $k (sort {$is_watched->{$a}->{user} cmp $is_watched->{$b}->{'user'} || 
				 $is_watched->{$a}->{time} cmp $is_watched->{$b}->{'time'} } (keys %{$is_watched}) ) {
	    ## clean this up at some point -- skip user if user and/or display user is not = to specified 
	    my $skip =1;
	    ## --exclude_user array ref
	    next if ( grep { $_ =~ /$is_watched->{$k}->{'user'}/i } @{$options{'exclude_user'}});
	    next if ( $user_display->{$is_watched->{$k}->{user}}  && grep { $_ =~ /$user_display->{$is_watched->{$k}->{user}}/i } @{$options{'exclude_user'}});
	    
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
	    my ($user,$orig_user) = &FriendlyName($is_watched->{$k}->{user});
	    
	    ## stat -- quick and dirty -- to clean up later
	    $stats{$user}->{'total_duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    $stats{$user}->{'duration'}->{$serial} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
	    ## end
	    
	    next if !$options{'watched'};
	    if ($options{'nogrouping'}) {
		if (!$seen_user{$user}) {
		    $seen_user{$user} = 1;
		    print "\nUser: " . $user;
		    print ' ['. $orig_user .']' if $user ne $orig_user;
		    print "\n";
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
		    $seen{$skey}->{'orig_user'} = $orig_user;
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
		print "\nUser: " . $seen{$k}->{user};
		print ' ['. $seen{$k}->{orig_user} .']' if $seen{$k}->{user} ne $seen{$k}->{orig_user};
		print "\n";
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
##--watching
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
	    
	    ## --exclude_user array ref
	    next if ( grep { $_ =~ /$in_progress->{$k}->{'user'}/i } @{$options{'exclude_user'}});
	    next if ( $user_display->{$in_progress->{$k}->{user}}  && grep { $_ =~ /$user_display->{$in_progress->{$k}->{user}}/i } @{$options{'exclude_user'}});
	    
	    if ($options{'user'}) {
	    	$skip = 0 if $options{'user'} &&  $options{'user'} =~ /$in_progress->{$k}->{user}/i; ## allow real user
		$skip = 0 if $options{'user'} && $user_display->{$in_progress->{$k}->{user}} &&  $options{'user'} =~ /$user_display->{$in_progress->{$k}->{user}}/i; ## allow display_user
	    }  else {	$skip = 0;    }
	    next if $skip;
	    my $live_key = (split("_",$k))[0];
	    
	    ## use display name 
	    my ($user,$orig_user) = &FriendlyName($in_progress->{$k}->{user});
	    
	    if (!$seen{$user}) {
		$seen{$user} = 1;
		print "\nUser: " . $user;
		print ' ['. $orig_user .']' if $user ne $orig_user;
		print "\n";
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

## no options -- we can continue.. otherwise --stats, --watched, --watching or --notify MUST be specified
if (%options && !$options{'notify'} && !$options{'stats'} && !$options{'watched'} && !$options{'watching'} && !$options{'recently_added'} ) {
    print "\n* Skipping any Notifictions -- command line options set, use '--notify' or supply no options to enable notifications\n";
    exit;
}

#################################################################
## Notify -notify || no options = notify on watch/stopped streams
##--notify
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
		&Notify($info);
		print &consoletxt("Already Notified -- Sent again due to --debug") . "\n"; 
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

#################################################### SUB #########################################################################

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
    if ($debug) { print "\nformat: $format\n";}
    my $s = $format;
    my $regex = join "|", keys %alert;
    $regex = qr/$regex/;
    $s =~ s/{($regex)}/$alert{$1}/g;
    $orig =~ s/{($regex)}/$alert{$1}/g;
    ## $orig is pretty much deprecated..
    return ($s,$orig);
}

sub ConsoleLog() {
    my $msg = shift;
    my $print = shift;
    my $console;
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
    if ($notify->{'file'}->{'enabled'}) {	
	open FILE, ">>", $notify->{'file'}->{'filename'}  or die $!;
	print FILE "$console\n";
	close(FILE);
    }
    return 1;
}

sub Notify() {
    my $info = shift;
    my $ret_alert = shift;
    my $type = $info->{'ntype'};
    my ($alert,$orig) = &formatAlert($info);
    
    ## --exclude_user array ref -- do not notify if user is excluded.. however continue processing -- logging to DB - logging to file still happens.
    return 1 if ( grep { $_ =~ /$info->{'orig_user'}/i } @{$options{'exclude_user'}});
    return 1 if ( grep { $_ =~ /$info->{'user'}/i } @{$options{'exclude_user'}});
    
    ## only return the alert - do not notify -- used for CLI to keep formatting the same
    return &consoletxt($alert) if $ret_alert;
        
    my $push_type;
    if ($type =~ /start/) {	$push_type = 'push_watching';    } 
    if ($type =~ /stop/) {	$push_type = 'push_watched';    } 
    
    foreach my $provider (keys %{$notify}) {
	if ( ( $notify->{$provider}->{'enabled'} ) && ( $notify->{$provider}->{$push_type} || $provider =~ /file/)) { 
	    $notify_func{$provider}->($alert);
	}
    }

    ## OLD STYLE - to remove at a later date
    ## file logging
    #&ConsoleLog($alert);
    
    ## started :: watching
    #    if ($notify_started && $type =~ /start/) {
    #	my $push_type = 'push_watching';
    #	if ($notify->{'prowl'}->{'enabled'} && $notify->{'prowl'}->{$push_type})       { &NotifyProwl($alert); }
    #	if ($notify->{'pushover'}->{'enabled'} && $notify->{'pushover'}->{$push_type}) { &NotifyPushOver($alert);          }
    #	if ($notify->{'growl'}->{'enabled'} && $notify->{'growl'}->{$push_type})       { &NotifyGrowl($alert);             }
    #	if ($notify->{'twitter'}->{'enabled'} && $notify->{'twitter'}->{$push_type})   { &NotifyTwitter($alert);             }
    #	if ($notify->{'boxcar'}->{'enabled'} && $notify->{'boxcar'}->{$push_type})     { &NotifyBoxcar($alert);             }
    #    }
    #    
    #    ## stopped :: watched
    #    if ($notify_stopped && $type =~ /stop/) {    
    #	my $push_type = 'push_watched';
    #	if ($notify->{'prowl'}->{'enabled'} && $notify->{'prowl'}->{$push_type})       { &NotifyProwl($alert); }
    #	if ($notify->{'pushover'}->{'enabled'} && $notify->{'pushover'}->{$push_type}) { &NotifyPushOver($alert);          }
    #	if ($notify->{'growl'}->{'enabled'} && $notify->{'growl'}->{$push_type})       { &NotifyGrowl($alert);             }
    #	if ($notify->{'twitter'}->{'enabled'} && $notify->{'twitter'}->{$push_type})   { &NotifyTwitter($alert);             }
    #	if ($notify->{'boxcar'}->{'enabled'} && $notify->{'boxcar'}->{$push_type})     { &NotifyBoxcar($alert);             }
    #    }
    ## end OLD STYLE
}

sub RawNotify() {
    ### not used yet... probably never will be. -- to remove later
    my $alert = shift;
    my $push_type = shift; #[push_watched, push_watching or push_recently_added]
    
    my $ret_alert = shift;
    
    ## only return the alert - do not notify -- used for CLI to keep formatting the same
    return &consoletxt($alert) if $ret_alert;
    
    if ($notify->{'prowl'}->{'enabled'} && $notify->{'prowl'}->{$push_type})       { &NotifyProwl($alert);    }
    if ($notify->{'pushover'}->{'enabled'} && $notify->{'pushover'}->{$push_type}) { &NotifyPushOver($alert); }
    if ($notify->{'growl'}->{'enabled'} && $notify->{'growl'}->{$push_type})       { &NotifyGrowl($alert);    }
    if ($notify->{'twitter'}->{'enabled'} && $notify->{'twitter'}->{$push_type})   { &NotifyTwitter($alert);  }
    if ($notify->{'boxcar'}->{'enabled'} && $notify->{'boxcar'}->{$push_type})     { &NotifyBoxcar($alert);             }
    
    ## file logging
    &ConsoleLog($alert);
}

sub ProcessStart() {
    my ($xmlref,$db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year) = @_;
    my $xml =  XMLout($xmlref);
    
    my $sth = $dbh->prepare("insert into processed (session_id,title,platform,user,orig_title,orig_title_ep,genre,episode,season,summary,rating,year,xml) values (?,?,?,?,?,?,?,?,?,?,?,?,?)");
    $sth->execute($db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year,$xml) or die("Unable to execute query: $dbh->errstr\n");
    
    return  $dbh->sqlite_last_insert_rowid();
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
    my $url = "http://$server:$port/status/sessions";

    # Generate our HTTP request.
    my ($userAgent, $request, $response, $requestURL);
    $userAgent = LWP::UserAgent->new;
    $userAgent->agent($appname);
    $userAgent->env_proxy();
    $requestURL = $url;
    $request = HTTP::Request->new(GET => $requestURL);
    $response = $userAgent->request($request);
    
    if ($response->is_success) {
	my $XML  = $response->decoded_content();
	
	if ($debug_xml) {
	    print "URL: $url\n";
	    print "===================================XML CUT=================================================\n";
	    print $XML;
	    print "===================================XML END=================================================\n";
	}
	my $data = XMLin($XML,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
	return $data->{'Video'};
    } else {
	print "\nFailed to get request $url - The result: \n\n";
	print $response->decoded_content() . "\n\n";
	if ($options{debug}) {	 	
	    print "\n-----------------------------------DEBUG output----------------------------------\n\n";
	    print Dumper($response);
	    print "\n---------------------------------END DEBUG output---------------------------------\n\n";
	}
    	exit(2);	
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
}

sub NotifyTwitter() {
    #use Net::Twitter::Lite::WithAPIv1_1;
    #use Scalar::Util 'blessed';
    if ($provider_452->{'twitter'}) {
	if ($options{'debug'}) { print "Twitter 452: backing off\n"; }
	return 0;
    }
    my $alert = shift;
    my $tag = shift;
    my $url = shift;
    
    if ($tag) {	$alert .= ' #'.$appname.'_'.$tag;    }
    
    ## trim down alert..
    if (length($alert) > 139) {	$alert = substr($alert,0,140);    }
    
    ## url can be appended - twitter allows it even if the alert is 140 chars -- well it looks like 115 is max if URL is included..
    my $non_url_alert = $alert;
    if ($url) {
	if (length($alert) > 114) {	$alert = substr($alert,0,114);    }
	$alert .= ' '. $url;   
    }
    
    

    
    ## cleanup spaces
    $alert =~ s/\s+$//g;
    $alert =~ s/\s\s/ /g;

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
	#if ($err->code == 403 && $rl->{'resources'}->{'application'}->{'/application/rate_limit_status'}->{'remaining'} > 1) {
	if ($err->code == 403) {
	    $provider_452->{'twitter'} = 1;
	    print "Twitter error 403 (You are over the daily limit for sending Tweets. Please wait a few hours and try again.) -- setting twitter to back off additional notifictions\n";
	    return 0;
	}
    }
    
    if ( my $err = $@ ) {
	#die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
	if ($debug) {
	    warn "HTTP Response Code: ", $err->code, "\n",
	    "HTTP Message......: ", $err->message, "\n",
	    "Twitter error.....: ", $err->error, "\n";
	}
	return 0;
    }
    
    return 1;     ## success
}

sub NotifyProwl() {
    ## modified from: https://www.prowlapp.com/static/prowl.pl
    my %prowl = %{$notify->{prowl}};
    
    $prowl{'event'} = '';
    $prowl{'notification'} = shift;    
    
    #if ($prowl{'collapse'}) {
    #	my $orig = shift;
    #	#my @p = split(':',shift);
    #	#$prowl{'application'} .= ' - ' . shift(@p);
    #	$prowl{'event'} = $orig;
    #   }
    
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
	if ($debug) { 	    print "PROWL - Notification successfully posted.\n";}
	return 1;     ## success
    } elsif ($response->code == 401) {
	print STDERR "PROWL - Notification not posted: incorrect API key.\n";
    } else {
	print STDERR "PROWL - Notification not posted: $prowl{'notification'} " . $response->content . "\n";
    }
    return 0; # failed
}

sub NotifyPushOver() {
    my %po = %{$notify->{pushover}};    
    my $ua      = LWP::UserAgent->new();
    $po{'message'} = shift;
    
    my $response = $ua->post( "https://api.pushover.net/1/messages.json", [
				  "token" => $po{'token'},
				  "user" => $po{'user'},
				  "sound" => $po{'sound'},
				  "title" => $po{'title'},
				  "message" => $po{'message'},
			      ]);
    my $content  = $response->decoded_content();

    if ($content !~ /\"status\":1/) {
	print STDERR "Failed to post PushOver notification -- $po{'message'} result:$content\n";
	return 0;
    } 
    
    if ($debug) { print "PushOver - Notification successfully posted. $content\n";}
    return 1;     ## success
}

sub NotifyBoxcar() {
    ## this will try to notifiy via box car 
    # It will try to subscribe to the plexWatch service on boxcar if we get a 401 and resend the notification
    
    my %bc = %{$notify->{boxcar}};    
    $bc{'message'} = shift;
    
    if (!$bc{'email'}) {
	my $msg = "Please specify and email address for boxcar in config.pl";
	&ConsoleLog($msg);
    } else {
        my $response = &NotifyBoxcarPOST(\%bc);
	
	return 1 if $response->is_success;
	if ($response->{'_rc'} == 401) {
	    my $ua      = LWP::UserAgent->new();
	    my $msg = "$bc{'email'} is not subscribed to plexWatch service... trying to subscribe now";
	    &ConsoleLog($msg);
	    my $url = 'http://boxcar.io/devices/providers/'. $bc{'provider_key'} .'/notifications/subscribe';
	    my $response = $ua->post( $url, [
					  "email" => $bc{'email'},#
				      ]);
	    if (!$response->is_success) {
		my $msg = "$bc{'email'} subscription to plexWatch service failed. Is $bc{'email'} email registerd to your boxcar account?";
		&ConsoleLog($msg);
	    } else {
		## try notification again now that we are subscribed
		my $msg = "$bc{'email'} is now subscribed to plexWatch service. Trying to send notification again.";
		&ConsoleLog($msg);
		$response = &NotifyBoxcarPOST(\%bc);
		return 1 if $response->is_success;    
	    }
	}
    }
        
    print STDERR "Failed to post Boxcar notification - $bc{'message'}\n";
    return 0;
}

sub NotifyBoxcarPOST() {
    ## the actual post to boxcar
    my %bc = %{$_[0]};
    
    my $ua      = LWP::UserAgent->new();
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
    my $alert = shift;
    my %growl = %{$notify->{growl}};    
    if (!-f  $growl{'script'} ) {
	print STDERR "\nFailed to send GROWL notification -- $growl{'script'} does not exists\n";
	return 0;
    } else {
	system( $growl{'script'}, "-n", $growl{'application'}, "--image", $growl{'icon'}, "-m", $alert); 
	return 1; ## need better error checking here -- no mac, so I can't test it.
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
    my $orig_user = $user;
    $user = $user_display->{$user} if $user_display->{$user};
    return ($user,$orig_user);
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
    
    my ($user,$tmp) = &FriendlyName($orig_user);
    
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
    $ntype = 'stop' if $options{test_notify} =~ /watched/;
    
    
    $ntype = 'push_recently_added' if $options{test_notify} =~ /recent/;
    if ($ntype =~ /push_recently_added/) {
	my $alerts = ();
	$alerts->{'test'}->{'alert'} = 'NEW: '. ' test recently added alert';
	$alerts->{'test'}->{'alert_short'} = 'NEW: '. 'test recently added alert (short version)';
	$alerts->{'test'}->{'item_id'} = 'test_item_id';
	$alerts->{'test'}->{'debug_done'} = 'testing alert already done';
	$alerts->{'test'}->{'alert_url'} = 'https://github.com/ljunkie/plexWatch';
	&ProcessRAalerts($alerts,1);
    } else {
	
	$format_options->{'ntype'} = $ntype;
	my $info = &GetTestNotify($ntype);
	## notify if we have a valid DB results
	if ($info) {
	    foreach my $k (keys %{$info}) {
		my $start_epoch = $info->{$k}->{time} if $info->{$k}->{time}; ## DB only
		my $stop_epoch = $info->{$k}->{stopped} if $info->{$k}->{stopped}; ## DB only
		my $info = &info_from_xml($info->{$k}->{'xml'},$ntype,$start_epoch,$stop_epoch);
		&Notify($info);
	    }
	} 
	## notify the default format if there is not DB log yet.
	else {
	    &Notify($format_options);
	}
    }
    
    ## test notify -- exit 
    exit;
}


sub twittime() {
    ## twitters way of showing the date/time
    my $epoch = shift;
    my $date = (strftime "%I:%M%P %d %b %y", localtime($epoch));
    $date =~ s/^0//;
    return $date;
}

sub rrtime() {
    ## my way of showing the date/time
    my $epoch = shift;
    my $date = (strftime "%I:%M%P - %a %b ", localtime($epoch)) . suffer(strftime "%e", localtime($epoch)) . (strftime " %Y", localtime($epoch));
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
    my $type = shift;
    my $info = $data; ## fallback
    
    if ($type =~ /movie/i || $type=~/show/) {
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
    if ($type =~ /show/) {
	$info->{'episode'} = $data->{index};
	$info->{'season'} = $data->{parentIndex};
	if ($info->{'episode'} < 10) { $info->{'episode'} = 0 . $info->{'episode'};}
	if ($info->{'season'} < 10) { $info->{'season'} = 0 . $info->{'season'}; }
	$info->{'title'} = $data->{'grandparentTitle'} . ': '.  $data->{'title'} . ' s'.$info->{'season'} .'e'. $info->{'episode'};
	$info->{'imdb_title'} = $data->{'grandparentTitle'} . ': '.  $data->{'title'};
	
    }
    return $info;
}

sub GetSectionsIDs() {
    my $ua      = LWP::UserAgent->new();
    my $host = "http://$server:$port";
    my $sections = ();
    my $url = $host . '/library/sections';
    my $response = $ua->get( $url );
    if ( ! $response->is_success ) {
	print "Failed to get Library Sections from $url\n";
	exit(2);
    } else {
	my $content  = $response->decoded_content();
	my $data = XMLin($content);
	foreach  my $k (keys %{$data->{'Directory'}}) {
	    $sections->{'raw'}->{$k} = $data->{'Directory'}->{$k};
	    push @{$sections->{'types'}->{$data->{'Directory'}->{$k}->{'type'}}}, $k;
	}
    }
    return $sections;
}

sub GetItemMetadata() {
    my $ua      = LWP::UserAgent->new();
    my $host = "http://$server:$port";
    my $item = shift;
    my $full_uri = shift;
    my $url = $host . '/library/metadata/' . $item;
    if ($full_uri) {
	$url = $host . $item;
    }
    
    my $sections = ();
    my $response = $ua->get( $url );
    if ( ! $response->is_success ) {
	if ($options{'debug'}) {
	    print "Failed to get MetaData from from $url\n";
	    print Dumper($response);
	}
	return $response->{'_rc'} if $response->{'_rc'} == 404;
	exit(2);
    } else {
	my $content  = $response->decoded_content();
	#my $vid = XMLin($hash,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
	#my $data = XMLin($content, KeyAttr => { Role => ''} );
	my $data = XMLin($content);
	return $data->{'Video'} if $data->{'Video'};
    }
}

sub GetRecentlyAdded() {
    my $section = shift; ## array ref &GetRecentlyAdded([5,6,7]);
    my $hkey = shift;    ## array ref &GetRecentlyAdded([5,6,7]);
    
    my $ua      = LWP::UserAgent->new();
    my $host = "http://$server:$port";
    my $info = ();
    my %result;
    # /library/recentlyAdded <-- all sections
    # /library/sections/6/recentlyAdded <-- specific sectoin
    
    foreach my $section (@$section) {
	my $url = $host . '/library/sections/'.$section.'/recentlyAdded';
	
	## limit the output to the last 25 added.
	my $limit = '?query=c&X-Plex-Container-Start=0&X-Plex-Container-Size=25';
	my $response = $ua->get( $url . $limit);
	if ( ! $response->is_success ) {
	    print "Failed to get Library Sections from $url\n";
	    exit(2);
	} else {
	    my $content  = $response->decoded_content();
	    my $data = XMLin($content);
	    if (ref($info)) {
		my $tmp = $data->{$hkey};
		%result = (%$info, %$tmp);
		$info = \%result;
	    } else {
		$info = $data->{$hkey};
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
	
	## 'recently_added' table has columns for each provider -- we will notify and verify each provider has success. 
	## TODO - extend this logic into the normal notifications
	
	## new code - iterate through all providers.. same code block
	
	foreach my $provider (keys %{$notify}) {
	    # provider is globaly enable and provider push type is enable or is file

	    #elsif (&NotifyProwl($alerts->{$k}->{'alert'},'',$alerts->{$k}->{'alert_short'})) {
	    #    &SetNotified_RA($provider,$item_id)   if !$test_notify; 
	    #} 

	    if ( ( $notify->{$provider}->{'enabled'} ) && ( $notify->{$provider}->{$push_type} || $provider =~ /file/)) { 
		if ($ra_done->{$item_id}->{$provider}) {
		    printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
		} elsif ($is_old) {
		    &SetNotified_RA($provider,$item_id,3);
		}
		elsif ($notify_func{$provider}->($alerts->{$k}->{'alert'})) {
		    &SetNotified_RA($provider,$item_id)   if !$test_notify; 
		} 
		else {
		    if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
			print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
		    }
		}	
	    }
	}
	

	## OLD style - to cleanup
	## logging to file
	#
	#	$provider = 'file';
	#	## file logging
	#	if ($notify->{'file'}->{'enabled'}) {	
	#	    if ($ra_done->{$item_id}->{$provider}) {
	#		printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
	#	    } elsif ($is_old) {
	#		&SetNotified_RA($provider,$item_id,3);
	#	    } else {
	#		&ConsoleLog($alerts->{$k}->{'alert'});
	#		&SetNotified_RA($provider,$item_id)   if !$test_notify; 
	#	    }
	#	}
	#	####
	#	
	#	$provider = 'prowl';
	#	if ($notify->{$provider}->{'enabled'} && $notify->{$provider}->{$push_type}) { 
	#	    if ($ra_done->{$item_id}->{$provider}) {
	#		printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
	#	    } elsif ($is_old) {
	#		&SetNotified_RA($provider,$item_id,3);
	#	    }
	#	    elsif (&NotifyProwl($alerts->{$k}->{'alert'},'',$alerts->{$k}->{'alert_short'})) {
	#		&SetNotified_RA($provider,$item_id)   if !$test_notify; 
	#	    } 
	#	    else {
	#		if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
	#		    print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
	#		}
	#	    }
	#	}
	#	
	#	$provider = 'pushover';
	#	if ($notify->{$provider}->{'enabled'} && $notify->{$provider}->{$push_type}) { 
	#	    if ($ra_done->{$item_id}->{$provider}) {
	#		printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
	#	    } elsif ($is_old) {
	#		&SetNotified_RA($provider,$item_id,3);
	#	    }
	#	    elsif (&NotifyPushOver($alerts->{$k}->{'alert'})) {
	#		&SetNotified_RA($provider,$item_id)   if !$test_notify; 
	#	    } 
	#	    else {
	#		if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
	#		    print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
	#		}
	#	    }
	#	}
	#	
	#	$provider = 'growl';
	#	if ($notify->{$provider}->{'enabled'} && $notify->{$provider}->{$push_type}) { 
	#	    if ($ra_done->{$item_id}->{$provider}) {
	#		printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
	#	    } elsif ($is_old) {
	#		&SetNotified_RA($provider,$item_id,3);
	#	    } 
	#	    elsif (&NotifyGrowl($alerts->{$k}->{'alert'})) {
	#		&SetNotified_RA($provider,$item_id)   if !$test_notify; 
	#	    } 
	#	    else {
	#		if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
	#		    print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
	#		}
	#	    }
	#	}
	#	
	#	$provider = 'twitter';
	#	if ($notify->{$provider}->{'enabled'} && $notify->{$provider}->{$push_type}) { 
	#	    if ($ra_done->{$item_id}->{$provider}) {
	#		printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
	#	    } elsif ($is_old) {
	#		&SetNotified_RA($provider,$item_id,3);
	#	    }
	#	    elsif (&NotifyTwitter($alerts->{$k}->{'alert'},$alerts->{$k}->{'alert_tag'},$alerts->{$k}->{'alert_url'})) {
	#		&SetNotified_RA($provider,$item_id)   if !$test_notify; 
	#	    } 
	#	    else {
	#		if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
	#		    print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
	#		}
	#	    }
	#	}
	#	
	#	$provider = 'boxcar';
	#	if ($notify->{$provider}->{'enabled'} && $notify->{$provider}->{$push_type}) { 
	#	    if ($ra_done->{$item_id}->{$provider}) {
	#		printf("%s: %-8s %s [%s]\n", scalar localtime($ra_done->{$item_id}->{'time'}) , uc($provider) , $debug_done, $done_keys->{$ra_done->{$item_id}->{$provider}}) if $debug;
	#	    } elsif ($is_old) {
	#		&SetNotified_RA($provider,$item_id,3);
	#	    }
	#	    elsif (&NotifyBoxcar($alerts->{$k}->{'alert'})) {
	#		&SetNotified_RA($provider,$item_id)   if !$test_notify; 
	#	    } 
	#	    else {
	#		if (( $provider_452->{$provider} && $options{'debug'}) || $options{'debug'}) {
	#		    print "$provider Failed: we will try again next time.. $alerts->{$k}->{'alert'} \n";
	#		}
	#	    }
	#	}
	#	
	## END OLD STYLE
	
    } # end alerts

}

sub GetNotifyfuncs() {
    my %notify_func = (
	prowl => \&NotifyProwl,
	growl => \&NotifyGrowl,
	pushover => \&NotifyPushOver,
	twitter => \&NotifyTwitter,
	boxcar => \&NotifyBoxcar,
	file => \&ConsoleLog,
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





__DATA__

__END__

=head1 NAME 

plexWatch.pl - Notify and Log 'Now Playing' content from a Plex Media Server

=head1 SYNOPSIS


plexWatch.pl [options]

  Options:

   -notify=...                    Notify any content watched and or stopped [this is default with NO options given]

   -watched=...                   print watched content
        -start=...                    limit watched status output to content started AFTER/ON said date/time
        -stop=...                     limit watched status output to content started BEFORE/ON said date/time
        -nogrouping                   will show same title multiple times if user has watched/resumed title on the same day
        -user=...                     limit output to a specific user. Must be exact, case-insensitive

   -watching=...                  print content being watched

   -stats                         show total time watched / per day breakout included

   -recently_added=[show,movie]   notify when new movies or shows are added to the plex media server (required: config.pl: push_recentlyadded => 1) 

   #############################################################################################
    
   --format_options        : list all available formats for notifications and cli output

   --format_start=".."     : modify start notification :: --format_start='{user} watching {title} on {platform}'
 
   --format_stop=".."      : modify stop nottification :: --format_stop='{user} watched {title} on {platform} for {duration}'
 
   --format_watched=".."   : modify cli output for --watched  :: --format_watched='{user} watched {title} on {platform} for {duration}'

   --format_watching=".."  : modify cli output for --watching :: --format_watching='{user} watching {title} on {platform}'

   #############################################################################################
   * Debug Options

   -test_notify=start        send a test notifcation for a start event. To test a stop event use -test_notify=stop 
   -show_xml                 show xml result from api query
   -debug                    hit and miss - not very useful

=head1 OPTIONS

=over 15

=item B<-notify>

This will send you a notification through prowl, pushover, boxcar, growl and/or twitter. It will also log the event to a file and to the database.
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

=item B<-recently_added>

notify when new movies or shows are added to the plex media server (required: config.pl: push_recentlyadded => 1) 

 --recently_added=movie :: for movies
 --recently_added=show  :: for tv show/episodes

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


