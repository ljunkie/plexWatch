#!/usr/bin/perl

my $version = '0.3.4';
my $author_info = <<EOF;
##########################################
#   Author: Rob Reed
#  Created: 2013-06-26
# Modified: 2016-01-30 12:05 PST
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
use POSIX qw(strftime);
use File::Basename;
use warnings;
use Time::Local;
use open qw/:std :utf8/; ## default encoding of these filehandles all at once (binmode could also be used)
use utf8;
use Encode;
use JSON;
use IO::Socket::SSL qw( SSL_VERIFY_NONE);

## windows
if ($^O eq 'MSWin32') {

}
## non windows
if ($^O ne 'MSWin32') {
    require Time::ParseDate;
    Time::ParseDate->import();
}
## end

## load config file
my $dirname = dirname(__FILE__);
if (!-e $dirname .'/config.pl') {
    my $msg = "** missing file $dirname/config.pl. Did you move edit config.pl-dist and copy to config.pl?";
    &DebugLog($msg,1) if $msg;
    exit;
}
our ($data_dir, $server, $port, $appname, $user_display, $alert_format, $notify, $push_titles, $backup_opts, $myPlex_user, $myPlex_pass, $server_log, $log_client_ip, $debug_logging, $watched_show_completed, $watched_grouping_maxhr, $count_paused, $inc_non_library_content, @exclude_library_ids);
my @config_vars = ("data_dir", "server", "port", "appname", "user_display", "alert_format", "notify", "push_titles", "backup_opts", "myPlex_user", "myPlex_pass", "server_log", "log_client_ip", "debug_logging", "watched_show_completed", "watched_grouping_maxhr", "count_paused", "exclude_library_ids");
do $dirname.'/config.pl';

if (!$data_dir || !$server || !$port || !$appname || !$alert_format || !$notify) {
    ## TODO - make this information a little more useful!
    my $msg = "config file missing data";
    &DebugLog($msg,1) if $msg;
    exit;
}
## end

############################################
## Advanced Options (override in config.pl)

## always display a 100% watched show. I.E. if user watches show1 100%, then restarts it and stops at < 90%, show two lines
$watched_show_completed = 1 if !defined($watched_show_completed);

## how many hours between starts of the same show do we allow grouping? 24 is max (3 hour default)
$watched_grouping_maxhr = 3 if !defined($watched_grouping_maxhr);

## DO not include non library content by default ( channels )
$inc_non_library_content = 0 if !defined($inc_non_library_content);

my $max_ra_backlog = 2; ## not added to config yet ( keep trying RA backlog for 2 days max )
## end
############################################


## for now, let's warn the user if they have enabled logging of clients IP's and the server log is not found
if ($server_log && !-f $server_log) {
    my $msg = "warning: \$server_log is specified in config.pl and $server_log does not exist (required for logging of the clients IP address)\n" if $log_client_ip;
    &DebugLog($msg,1) if $msg;
}

## ONLY Load modules if used
if (&ProviderEnabled('twitter')) {
    require Net::Twitter::Lite;
    require Net::Twitter::Lite::WithAPIv1_1;
    require Net::OAuth;
    require Scalar::Util;
    Net::Twitter::Lite->import();
    Net::Twitter::Lite::WithAPIv1_1->import();
    Net::OAuth->import();
    Scalar::Util->import('blessed');
}

if (&ProviderEnabled('GNTP')) {
    require Growl::GNTP;
    Growl::GNTP->import();
}

if (&ProviderEnabled('EMAIL')) {
    require Net::SMTPS;
    Net::SMTPS->import();
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
    'streamtype_extended' => '"Direct Play" or "Audio:copy Video:transcode"',
    'streamtype' => 'T or D - for Transcoded or Direct',
    'transcoded' => '1 or 0 - if transcoded',
    'state' => 'playing, paused or buffering [ or stopped ] (useful on --watching)',
    'percent_complete' => 'Percent of video watched -- user could have only watched 5 minutes, but skipped to end = 100%',
    'ip_address' => 'Client IP Address',
};

if (!-d $data_dir) {
    my $msg = "** Sorry. Please create your datadir $data_dir";
    &DebugLog($msg,1) if $msg;
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
           'exclude_library_id:s@',
           'watching',
           'notify',
           'debug:s',
           'start:s',
           'stop:s',
           'format_start:s',
           'format_stop:s',
           'format_watched:s',
           'format_watching:s',
           'format_options',
           'test_notify:s',
           'recently_added:s',
           'id:s@',
           'version',
           'backup',
           'clean_extras',
           'show_xml',
           'help|?'
    ) or pod2usage(2);
pod2usage(-verbose => 2) if (exists($options{'help'}));

if ($options{version}) {
    print "\n\tVersion: $version\n\n";
    print "$author_info\n";
    exit;
}



my $debug_xml = $options{'show_xml'};

## ONLY load modules if used
if (defined($options{debug})) {
    require Data::Dumper;
    Data::Dumper->import();
    if ($options{debug} =~ /\d/ && $options{debug} > 1) {
        require diagnostics;
        diagnostics->import();
    } else {
        $options{debug} = 1;
    }
}
my $debug = $options{'debug'};

if ($options{'format_options'}) {
    print "\nFormat Options for alerts\n";
    print "\n\t    --start='" . $alert_format->{'start'} ."'";
    print "\n\t     --stop='" . $alert_format->{'stop'} ."'";
    print "\n\t  --watched='" . $alert_format->{'watched'} ."'";
    print "\n\t --watching='" . $alert_format->{'watching'} ."'";
    print "\n\n";

    foreach my $k (sort keys %{$format_options}) {
        printf("%25s %s\n", "{$k}", $format_options->{$k});
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

my $DBversion =  &checkVersion();
if ($DBversion ne $version) {
    print "* Upgrading the plexWatch from $DBversion to $version -- (Forcing Backup)\n";
    $options{'backup'} = 1;
}

&UpdateConfig(\@config_vars);

# clean any extras we may have logged. Make sure to run this before any
# backup or grouped table update as those come along with this.
if ($options{'clean_extras'}) {
    &extrasCleaner();
    exit;
}

if (&getLastGroupedTime() == 0) {    &UpdateGroupedTable;} ## update DB table if first run.

&BackupSQlite; ## check if the SQLdb needs to be backed up

## update any missing rating keys
&updateRatingKeys();

my $PMS_token = &PMSToken(); # sets token if required

########################################## START MAIN #######################################################

## show what the notify alerts will look like
if  (defined($options{test_notify})) {
    &RunTestNotify();
    exit;
}

####################################################################
## RECENTLY ADDED
if (defined($options{'recently_added'})) {
    my $plex_sections = &GetSectionsIDs(); ## allow for multiple sections with the same type (movie, show, etc) -- or different types (2013-08-01)

    my @want;
    my @merged = ();
    my $hkey = 'Video'; # for now, the only available option is Video
    ## backwards compatibility
    if (!$options{'id'}) {
        if ($options{'recently_added'} =~ /movie/i) {
            push @want , 'movie';
        }
        ## TO NOTE: plex used show and episode off an on. code for both
        if ($options{'recently_added'} =~ /show|tv|episode/i) {
            push @want , 'show';
        }
        foreach my $w (@want) {
            foreach my $v (@{$plex_sections->{'types'}->{$w}}) {   push (@merged, $v); }
        }
    } else {
        # use the specific ID's specified
        foreach my $id ( @{$options{'id'}} ) {
            if (ref($plex_sections->{'raw'}->{$id})) {
                push @want , $plex_sections->{'raw'}->{$id}->{'type'};
                push @merged , $id;
            } else {
                print "\n\t**FAILURE - Section ID:$id does not exists!\n";
            }
        }
    }

    ## show usage if the command didn't fit the bill
    if (!@merged) {
        print "\n\t* Available Sections:\n\n";
        printf("\t%-5s %-20s %-10s %-20s\n", 'ID','Title','Type','Path');
        print "\t-------------------------------------------------------------------\n";
        foreach my $key (keys %{$plex_sections->{'raw'}}) {
            next if $plex_sections->{'raw'}->{$key}->{'type'} !~ /movie|show|tv|episode/;
            printf("\t%-5s %-20s %-10s %-20s\n", $key,$plex_sections->{'raw'}->{$key}->{'title'},$plex_sections->{'raw'}->{$key}->{'type'}, $plex_sections->{'raw'}->{$key}->{'Location'}->{'path'});
        }

        my $msg = "\n\t* Usage: \n\n";
        $msg .= sprintf("\t%-22s: %s\n",'All Movie Sections',"$0 --recently_added=movie");
        $msg .= sprintf("\t%-22s: %s\n",'All Movie/TV Sections',"$0 --recently_added=movie,show");
        $msg .= sprintf("\t%-22s: %s\n",'Specific Section(s)',"$0 --recently_added --id=# --id=#");
        print $msg . "\n";
        exit;
    }

    my $info = &GetRecentlyAdded(\@merged,$hkey);
    my $alerts = (); # containers to push alerts from oldest -> newest

    my %seen;
    foreach my $k (keys %{$info}) {

        $seen{$k} = 1; ## alert seen
        if (!ref($info->{$k})) {
            my $msg = "Skipping KEY '$k' (expected key =~ '/library/metadata/###') -- it's not a hash ref?\n";
            $msg .= "\$info->{'$k'} is not a hash ref?\n";
            &DebugLog($msg,1) if $msg;
            print Dumper($info->{$k}) if $options{debug};
            next;
        }

        my $item = &ParseDataItem($info->{$k});
        next if (!ref($item) or !$item->{'title'} or $item->{'title'} !~ /\w+/);    ## verify we can parse the metadata ( sometimes the scanner is still filling in the info )
        my $res = &RAdataAlert($k,$item);
        next if (!ref($res) or !$res->{'alert'} or $res->{'alert'} !~ /\w+/ );  ## verify we can parse the metadata ( sometimes the scanner is still filling in the info )

        $alerts->{$item->{addedAt}.$k} = $res;
    }


    ## RA backlog - make sure we have all alerts -- some might has been added previously but notification failed and newer content has purged the results above
    my $ra_done = &GetRecentlyAddedDB($max_ra_backlog);
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
                my $ra_max_fail_days = $max_ra_backlog; ## TODO: advanced config options?
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
                    my $msg = "$item->{'title'} is NOT in current releases -- we failed to notify previously, so trying again";
                    &DebugLog($msg,1) if $msg;
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
    my ($alert_url);
    my $media;
    $media .= $item->{'videoResolution'}.'p ' if $item->{'videoResolution'};
    $media .= $item->{'audioChannels'}.'ch' if $item->{'audioChannels'};
    ##my $twitter; #twitter sucks... has to be short. --- might use this later.
    if ($item->{'type'} eq 'show' || $item->{'type'} eq 'episode') {
        $alert = $item->{'title'};
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

    $result->{'alert'} = $alert;
    $result->{'item_id'} = $item_id;
    $result->{'debug_done'} = $debug_done;
    $result->{'alert_url'} = $alert_url;
    $result->{'item_type'} = $item->{'type'};

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

## debug for now -- force updating the watched table

####################################################################
## print all watched content
##--watched

&ShowWatched;

## no options -- we can continue.. otherwise --stats, --watched, --watching or --notify MUST be specified
if (%options && !$options{'notify'} && !$options{'stats'} && !$options{'watched'} && !$options{'watching'} && !defined($options{'recently_added'}) ) {
    my $msg =  "* Skipping any Notifications -- command line options set, use '--notify' or supply no options to enable notifications";
    print "\n$msg\n\n";
    &DebugLog($msg) if $msg;
    exit;
}

## set notify to 1 if we call --watching ( we need to either log start/update/stop current progress)
if ($options{'watching'} && !$options{'notify'}) {
    $options{'notify'} = 2; #set notify to 2 -- meaning will will run through notify process to update current info, but we wiill not set as notified
}
elsif (!%options) {
    $options{'notify'} = 1;
}

#################################################################
## Notify -notify || no options = notify on watch/stopped streams
##--notify
if ($options{'notify'}) {
    my $live = &GetSessions();    ## query API for current streams
    my $started= &GetStarted();   ## query streams already started/not stopped
    my $playing = ();             ## container of now playing id's - used for stopped status/notification


    ###########################################################################
    ## nothing being watched.. verify all notification went out
    ## this shouldn't happen ( only happened during development when I was testing -- but just in case )
    #### to fix

    ## Quick hack to notify stopped content before start -- get a list of playing content
    foreach my $k (keys %{$live}) {
        my $userID = $live->{$k}->{User}->{id};
        $userID = 'Local' if !$userID;
        my $db_key = $k . '_' . $live->{$k}->{key} . '_' . $userID;
        $playing->{$db_key} = 1;
    }

    ## make sure we send out notifications -- this can happen when people call --watching and a new video started or stopped before --notify was called
    my $did_unnotify = 0;
    if ($options{'notify'} != 2) {
        my $un = &GetUnNotified();
        foreach my $k (keys %{$un}) {
            my $start_epoch = $un->{$k}->{time} if $un->{$k}->{time};
            my $stop_epoch = $un->{$k}->{stopped} if $un->{$k}->{stopped};
            $stop_epoch = time() if !$stop_epoch; # we may not have a stop time yet.. lets set it.
            my $ntype = 'stop';
            $ntype = 'start' if ($playing->{$k});
            my $paused = &getSecPaused($k);
            my $info = &info_from_xml($un->{$k}->{'xml'},$ntype,$start_epoch,$stop_epoch,$paused);
            $info->{'ip_address'} = $un->{$k}->{ip_address};
            &DebugLog("sending unnotify for alert for ".$un->{$k}->{user}.':'.$un->{$k}->{title});
            &Notify($info);
            &SetNotified($un->{$k}->{id});
            $did_unnotify = 1;
        }
    }
    $started= &GetStarted() if $did_unnotify; ## refresh started if we notified

    ## Notify on any Stop
    ## Iterate through all non-stopped content and notify if not playing
    if (ref($started)) {
        foreach my $k (keys %{$started}) {
            if (!$playing->{$k}) {
                my $start_epoch = $started->{$k}->{time} if $started->{$k}->{time};
                my $stop_epoch = time();

                ## process the update - need to supply the original XML (as an xml_ref) and session_id
                my $xml_ref = XMLin($started->{$k}->{'xml'},KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
                $xml_ref->{Player}->{'state'} = 'stopped'; # force state as 'stopped' (since this XML is from the DB)
                &ProcessUpdate($xml_ref, $started->{$k}->{'session_id'} ); ## go through normal update -- will set paused counter etc..

                my $paused = &getSecPaused($k);
                my $info = &info_from_xml($started->{$k}->{'xml'},'stop',$start_epoch,$stop_epoch,$paused);
                $info->{'ip_address'} = $started->{$k}->{ip_address};
                &SetStopped($started->{$k}->{id},$stop_epoch);  # will mark as unnotified

                $info->{'decoded'} = 1; ## XML - already decoded
                &Notify($info) if $options{'notify'} != 2;
                &SetNotified($started->{$k}->{id}) if $options{'notify'} != 2;
            }
        }
    }

    ## Notify on start/now playing
    foreach my $k (keys %{$live}) {
        my $start_epoch = time();
        my $stop_epoch = ''; ## not stopped yet
        my $info = &info_from_xml(XMLout($live->{$k}),'start',$start_epoch,$stop_epoch,0);
        $info->{'decoded'} = 1; ## live XML - already decoded

        ## for insert
        my $userID = $info->{userID};
        $userID = 'Local' if !$userID;
        my $db_key = $k . '_' . $live->{$k}->{key} . '_' . $userID;

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
                &Notify($info,'',1)  if $options{'notify'} != 2;
            }

            if ($debug) {
                &Notify($info) if $options{'notify'} != 2;
                my $msg = "Already Notified -- Sent again due to --debug";
                &DebugLog($msg,1) if $msg && $options{'notify'} != 2;
            };
        }
        ## unnotified - insert into DB and notify
        else {
            ## quick and dirty hack for client IP address
            $info->{'ip_address'} = &LocateIP($info) if ref $info;
            ## end the dirty feeling

            my $insert_id = &ProcessStart($live->{$k},$db_key,$info->{'title'},$info->{'platform'},$info->{'orig_user'},$info->{'orig_title'},$info->{'orig_title_ep'},$info->{'genre'},$info->{'episode'},$info->{'season'},$info->{'summary'},$info->{'rating'},$info->{'year'},$info->{'ip_address'}, $info->{'ratingKey'}, $info->{'parentRatingKey'}, $info->{'grandparentRatingKey'} );
            &Notify($info) if $options{'notify'} != 2;
            ## should probably have some checks to make sure we were notified.. TODO
            &SetNotified($insert_id)  if $options{'notify'} != 2;
        }
    }
}


#####################################################
## print content being watched
##--watching
if ($options{'watching'}) {
    my $in_progress = &GetInProgress();
    my $live = &GetSessions();    ## query API for current streams
    my $found_live = 0;

    printf ("\n======================================= %s ========================================",'Watching');

    my %seen = ();
    if (keys %{$in_progress}) {
        print "\n";
        foreach my $k (sort { $in_progress->{$a}->{user} cmp $in_progress->{$b}->{'user'} || $in_progress->{$a}->{time} cmp $in_progress->{$b}->{'time'} } (keys %{$in_progress}) ) {
            my $live_key = (split("_",$k))[0];
            if (!$live->{$live_key}) {
                #print "must of been stopped-- but unnotified";
                next;
            }
            $found_live = 1;
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
            }  else {   $skip = 0;    }

            next if $skip;

            if (!$seen{$user}) {
                $seen{$user} = 1;
                print "\nUser: " .decode('utf8',  $user);
                print ' ['. $orig_user .']' if $user ne $orig_user;
                print "\n";
            }

            my $time = localtime ($in_progress->{$k}->{time} );

            my $paused = &getSecPaused($k);
            my $info = &info_from_xml(XMLout($live->{$live_key}),'watching',$in_progress->{$k}->{time},time(),$paused);

            ## encode the user for output ( only if different -- otherwise we will take what Plex has set)
            if ($user ne $orig_user) {
                $info->{'user'} = encode('utf8',  $info->{'user'}) if eval { encode('UTF-8',   $info->{'user'}); 1 };
            } elsif  ($info->{time} > 1392090762) {
                # everything after 2013-02-11 is not encoded properly ( excluding above which is special )
                $info->{'user'} = encode('utf8',  $info->{'user'}) if eval { encode('UTF-8',   $info->{'user'}); 1 };
            }

            $info->{'ip_address'} = $in_progress->{$k}->{ip_address};

            my $alert = &Notify($info,1); ## only return formated alert
            printf(" %s: %s\n",$time, $alert);
        }

    }
    print "\n * nothing in progress\n"  if !$found_live;
    print " \n";
}

#################################################### SUB #########################################################################

sub formatAlert() {
    my $info = shift;

    return ($info) if !ref($info);

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

    my $format_key = 'alert_format';

    # external provider (scripts) uses script_format
    if (defined($provider) && $provider eq 'external') {
        $format_key = 'script_format';
        return -1 if !$n_prov_format->{$format_key}->{$type};
        $format = $n_prov_format->{$format_key}->{$type};
    } else {
        foreach my $tkey (@types) {
            if ($type =~ /$tkey/i) {
                $format = $alert_format->{$tkey}; # default alert formats per notify type
                $format = $n_prov_format->{$format_key}->{$tkey} if $n_prov_format->{$format_key}->{$tkey}; # provider override
            }
        }
    }

    if ($debug) { print "\nformat: $format\n";}

    ## just to be sure we don't have any conflicts -- use double curly brackets {{variable}} ( users still only use 1 {variable} )
    $format =~ s/{/{{/g;
    $format =~ s/}/}}/g;
    my $regex = join "|", keys %{$info};
    $regex = qr/$regex/;

    ## decoding doesn't play nice if we have mixed content ( one variable umlauts, another cryillic)  try and decode each string
    if (!$info->{'decoded'}) {
        foreach my $key (keys %{$info}) {
            ## save come cpu cycles.
            if (!ref($info->{$key}) && $format =~ /{$key}/) {
                $info->{$key} = decode('utf8',$info->{$key}) if eval { decode('UTF-8', $info->{$key}); 1 };
            }
        }
    }

    $format =~ s/{{($regex)}}/$info->{$1}/g; ## regex replace variables
    $format =~ s/\[\]//g;                 ## trim any empty variable encapsulated in []
    $format =~ s/\s+/ /g;                 ## remove double spaces
    $format =~ s/\\n/\n/g;                ## allow \n to be an actual new line
    $format =~ s/{{newline}}/\n/g;        ## allow \n to be an actual new line

    ## special for now.. might make this more useful -- just thrown together since email can include a ton of info

    if ($format =~ /{{all_details}}/i) {
        $format =~ s/\s*{{all_details}}\s*//i;
        $format .= sprintf("\n\n%10s %s\n","","-----All Details-----");
        my $f_extra;
        foreach my $key (keys %{$info} ) {
            if (!ref($info->{$key})) {
                if ($info->{$key}) {
                    my $value = $info->{$key};
                    if (!$info->{'decoded'}) {
                        $value = decode('utf8',$value) if eval { decode('UTF-8', $value); 1 };
                    }
                    $format .= sprintf("%20s: %s\n",$key,$value);
                }
            } else {
                $f_extra .= sprintf("\n\n%10s %s\n","","-----$key-----");
                foreach my $k2 (keys %{$info->{$key}} ) {
                    if (!ref($info->{$key}->{$k2})) {
                        my $value = $info->{$key}->{$k2};
                        if (!$info->{'decoded'}) {
                            $value = decode('utf8',$value) if eval { decode('UTF-8', $value); 1 };
                        }
                        $f_extra .= sprintf("%20s: %s\n",$k2,$value);
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
        if ($alert_options->{'user'}) {
            if ($msg !~ /\b$alert_options->{'user'}\b/i) {
                $prefix .= $alert_options->{'user'} . ' ' if $alert_options->{'user'};
            }
            if ($msg !~ /\b$push_type_titles->{$alert_options->{'push_type'}}\b/i) {
                $prefix .= $push_type_titles->{$alert_options->{'push_type'}} . ' ' if $alert_options->{'push_type'};
            }
        }
        ## append type (movie, episode) if supplied
        $prefix .= ucfirst($alert_options->{'item_type'}) . ' ' if $alert_options->{'item_type'};
        $prefix =~ s/\s+$//g;
    }

    $msg = $prefix . ': ' . $msg if $prefix;

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

    if (ref($alert_options) && $alert_options->{'user'}) {
        if ($msg !~ /\b$alert_options->{'user'}\b/i) {
            $prefix .= $alert_options->{'user'} . ' ' if $alert_options->{'user'};
        }
        if ($msg !~ /\b$push_type_titles->{$alert_options->{'push_type'}}\b/i) {
            $prefix .= $push_type_titles->{$alert_options->{'push_type'}} . ' ' if $alert_options->{'push_type'};
        }
    } else {
        $prefix .= $push_type_titles->{$alert_options->{'push_type'}} . ' ' if $alert_options->{'push_type'};
    }

    ## append type (movie, episode) if supplied
    $prefix .= ucfirst($alert_options->{'item_type'}) . ' ' if $alert_options->{'item_type'};
    $prefix =~ s/\s+$//g if $prefix;
    $msg = $prefix . ': ' . $msg if $prefix;


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

sub NotifyExternal() {
    my $provider = 'external';

    # This is just a pretty basic routine to call external scripts.

    my $info = shift;
    my $alert_options = shift;

    my ($success,$error);
    foreach my $k (keys %{$notify->{$provider}}) {
        my ($command) = &formatAlert($info,$provider,$k);
        next if $command eq -1;

        my $push_type = $alert_options->{'push_type'};
        if (ref $notify->{$provider}->{$k} && $notify->{$provider}->{$k}->{'enabled'}  &&  $notify->{$provider}->{$k}->{$push_type}) {
            print "$provider key:$k enabled for this $alert_options->{'push_type'}\n" if $debug;
        } else {
            print "$provider key:$k NOT enabled for this $alert_options->{'push_type'} - skipping\n" if $debug;
            next;
        }

        &DebugLog($provider . '-' . $k . ': ' . $push_type . ' enabled -> run cmd: ' . $command);
        system($command)
    }

    return 1; # for now... success!
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

    if ($type =~ /start/)  { $push_type = 'push_watching';  }
    if ($type =~ /stop/)   { $push_type = 'push_watched';   }
    if ($type =~ /resume/) { $push_type = 'push_resumed';   }
    if ($type =~ /pause/)  { $push_type = 'push_paused';    }

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
    my ($xmlref,$db_key,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year,$ip,$ratingKey,$parentRatingKey,$grandparentRatingKey) = @_;
    my $xml =  XMLout($xmlref);
    my $sth = $dbh->prepare("insert into processed (session_id,ip_address,title,platform,user,orig_title,orig_title_ep,genre,episode,season,summary,rating,year,xml,ratingKey,parentRatingKey,grandparentRatingKey) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    $sth->execute($db_key,$ip,$title,$platform,$user,$orig_title,$orig_title_ep,$genre,$episode,$season,$summary,$rating,$year,$xml,$ratingKey,$parentRatingKey,$grandparentRatingKey) or die("Unable to execute query: $dbh->errstr\n");
    return  $dbh->sqlite_last_insert_rowid();
}

sub ProcessGrouped() {
    my $hash_ref = shift;
    my $option = shift; #1 = force default (nothing special), #2 delete grouped table and process
    my %seen = %$hash_ref;

    if (defined($option) and $option == 2) {
        print "\t*Optimizing grouped table...";
        my $delete = $dbh->prepare("DELETE FROM grouped");
        $delete->execute;
        my $vaccum = $dbh->prepare("VACUUM");
        $vaccum->execute;
    }

    my $insert = $dbh->prepare("insert into grouped (session_id,time,stopped,paused_counter,ip_address,title,platform,user,orig_title,orig_title_ep,genre,episode,season,summary,rating,year,xml,ratingKey,parentRatingKey,grandparentRatingKey) ".
                               "values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    my $update = $dbh->prepare("update grouped set stopped = ?, paused_counter = ?, ip_address = ?, platform = ?, xml = ? where id = ?");

    # lock for changes - this is a HUGE speed increase ( takes < second to insert/update 1500 records )
    $dbh->begin_work;

    foreach my $k (sort {  $seen{$a}->{time} cmp $seen{$b}->{'time'}  } (keys %seen) ) {
        my $info = $seen{$k};
        ## check if record exists
        my $check = $dbh->prepare('select id,stopped,paused_counter from grouped where session_id = ? and time = ?');
        $check->execute($info->{'db_key'},$info->{'time'}) or die("Unable to execute query: $dbh->errstr\n");
        my @row = $check->fetchrow_array;

        ## New record - Insert
        if (!$row[0]) {
            $insert->execute($info->{'db_key'},$info->{'time'},$info->{'stopped'},$info->{'paused'},$info->{'ip_address'},$info->{'title'},$info->{'platform'},$info->{'orig_user'},$info->{'orig_title'},$info->{'orig_title_ep'},$info->{'genre'},$info->{'episode'},$info->{'season'},$info->{'summary'},$info->{'rating'},$info->{'year'},$info->{'xml'}, $info->{'ratingKey'},$info->{'parentRatingKey'},$info->{'grandparentRatingKey'}) or die("Unable to execute query: $dbh->errstr\n");
        }
        ## Existing record -- check if new info
        else {
            # we can key off of stopped, paused -- stopped will probably be the only key since we are only looking for watched content now
            if ($row[1] ne $info->{'stopped'} || $row[2] ne $info->{'paused'}) {
                $update->execute($info->{'stopped'},$info->{'paused'},$info->{'ip_address'},$info->{'platform'},$info->{'xml'},$row[0]) or die("Unable to execute query: $dbh->errstr\n");
            }
        }
    }

    # commit changes
    $dbh->commit;

    print "Done\n"  if (defined($option) and $option == 2);
}


sub UpdateConfig() {
    my $ref = shift;
    my @vars = @$ref;
    my $USER_CONFIG = {};
    foreach my $name (@vars) {
        if (defined(${$main::{$name}}))  {
            $USER_CONFIG->{$name} = ${$main::{$name}};
        }
    }
    use Data::Dumper;
    my $json = JSON->new->allow_nonref;
    my $json_s = $json->encode($USER_CONFIG);
    my $json_p = $json->pretty->encode( $USER_CONFIG );

    my $ref_blob = Dumper($USER_CONFIG);

    my $insert = $dbh->prepare("insert into config (version,json,json_pretty,hash_ref) values (?,?,?,?)");
    my $delete = $dbh->prepare("DELETE FROM config");

    # lock for changes - this is a HUGE speed increase ( takes < second to insert/update 1500 records )
    $dbh->begin_work;
    $delete->execute;
    $insert->execute($version,$json_s,$json_p,$ref_blob) or die("Unable to execute query: $dbh->errstr\n");
    # commit changes
    $dbh->commit;
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

                my $ipRegex = '\[[f:]*([\d\.\:a-f]*?)\:\d+\]'; # works with 0.9.9.3
                # ipv4    [192.168.1.5:60847]
                # ipv4v6  [ffff::192.168.1.5:60847]
                # ipv6    [2001:0db8:0000:0000:0000:ff00:0042:8329:60847]
                my $bw = File::ReadBackwards->new( $log ) or die "can't read 'log_file' $!" ;

                my $ip;
                my $find = $href->{'machineIdentifier'};
                my $item = $href->{'ratingKey'};

                my $d_out = "Locating IP for $href->{ratingKey}:$href->{'machineIdentifier'} [$href->{'user'}:$href->{'title'}] from $log... ";
                my $count = 0;
                while( defined( my $log_line = $bw->readline ) && !$ip) {
                    last if ($count > $max_lines);
                    $count++;
                    next if $log_line =~ /\[127\.0\.0\.1:\d+\]/; # ignore local request [ usually PUT requests, not GET|HEAD ]

                    #0.9.9.3+ -- IP in the beginnng of the log
                    if ($log_line =~ /\s+$ipRegex\s+(GET|HEAD]).*[^\d]$item.*(X-Plex-Client-Identifier|session)=$find/i) {
                        $ip = $1;
                        $match = $log_line . " [ by $2:$find + item:$item]";
                    }
                    elsif ($log_line =~ /\s+$ipRegex\s+(GET|HEAD).*(X-Plex-Client-Identifier|session)=$find/i) {
                        $ip = $1;
                        $match = $log_line . " [ by $2:$find only]";
                    }
                    if ($log_line =~ /\s+$ipRegex\s+(GET|HEAD]).*$find/i) {
                        $ip = $1;
                        $match = $log_line . " [ by client:$find only]";
                    }

                    # pre 0.9.9.3
                    elsif ($log_line =~ /(GET|HEAD]).*[^\d]$item.*(X-Plex-Client-Identifier|session)=$find.*\s+\[(.*)\:\d+\]/i) {
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
                        next if $log_line =~ /\[127\.0\.0\.1:\d+\]/; # ignore local request [ usually PUT requests, not GET|HEAD ]

                        #0.9.9.3+ -- IP in the beginnng of the log
                        if ($log_line =~ /$ipRegex.*GET.*playing.*ratingKey=$find[^\d]/) {
                            $ip = $1;
                            $match = $log_line . "[ fallback match 1 ]";
                        }
                        elsif ($log_line =~ /$ipRegex.*GET.*\/$find\?checkFiles/) {
                            $ip = $1;
                            $match = $log_line . "[ fallback match 2 ]";
                        }
                        elsif ($log_line =~ /$ipRegex.*GET.*[^\d]$find[^\d]/) {
                            $ip = $1;
                            $match = $log_line . "[ fallback match 3 ]";
                        }

                        # pre 0.9.9.2
                        elsif ($log_line =~ /GET.*playing.*ratingKey=$find[^\d].*\s+\[(.*)\:\d+\]/) {
                            $ip = $1;
                            $match = $log_line . "[ fallback match 1 pre ]";
                        }
                        elsif ($log_line =~ /GET.*\/$find\?checkFiles.*\s+\[(.*)\:\d+\]/) {
                            $ip = $1;
                            $match = $log_line . "[ fallback match 2 pre ]";
                        }
                        elsif ($log_line =~ /GET.*[^\d]$find[^\d].*\s+\[(.*)\:\d+\]/) {
                            $ip = $1;
                            $match = $log_line . "[ fallback match 3 pre]";
                        }

                    }
                    $d_out .= $ip if $ip;
                    $d_out .= "NO IP found ($count lines searched)" if !$ip;
                    &DebugLog($d_out);
                    &DebugLog("$ip log match (line $count): $match") if $ip;
                }

                ## cleanup IP address and return
                if ($ip) {
                    $ip =~ s/^::ffff://g; ## clean ipv6 compatible address
                    return $ip;
                }
            }
        }
    }
}

sub ProcessUpdate() {
    my ($xmlref,$db_key,$ip_address) = @_;
    my ($sess,$key) = split("_",$db_key);

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
        $state = 'playing' if $state =~ /buffering/i;
        $cmd = "select paused,paused_counter from processed where session_id = ?";
        $sth = $dbh->prepare($cmd);
        $sth->execute($db_key) or die("Unable to execute query: $dbh->errstr\n");
        my $p = $sth->fetchrow_hashref;

        $p_counter = $p->{'paused_counter'} if $p->{'paused_counter'};
        my $p_epoch = $p->{'paused'} if $p->{'paused'};
        my $prev_state = (defined($p_epoch)) ? "paused" : "playing";
        ## video is paused: verify DB has the pause epoch set


        if ($state && ($prev_state !~ /$state/i)) {
            $state_change=1;
            my $dmsg = "* Video State: $state [prev: $prev_state]\n" if defined($state);
            &DebugLog($dmsg) if $dmsg;
        }

        ## bug fix for now -- might want to add buffering as an option to notify later
        my $state_change=0 if $state =~ /buffering/i;

        my $now = time();
        if (defined($state) && $state =~ /paused/i) {
            #my $sec = $now-$p_epoch;
            #my $total_sec = $p_counter+$sec;
            if (!$p_epoch) {
                $extra .= sprintf(",paused = %s",$now);
                my $dmsg = sprintf "* Marking as as Paused on %s [%s]\n",scalar localtime($now),$now if defined($state);
                &DebugLog($dmsg) if $dmsg;
            } else {
                $p_counter += $now-$p_epoch; ## only for display on debug -- do NOT update db with this.
                my $dmsg = sprintf "* Already marked as Paused on %s [%s]\n",scalar localtime($p_epoch),$p_epoch if defined($state);
                &DebugLog($dmsg) if $dmsg;
                #$extra .= sprintf(",paused_counter = %s",$total_sec); #update counter
            }
        }
        ## Video is not paused -- verify DB not paused and update counter
        else {
            if ($p_epoch) {
                my $sec = $now-$p_epoch;
                $p_counter += $sec;
                $extra .= sprintf(",paused = %s",'null'); # set Paused to NULL
                $extra .= sprintf(",paused_counter = %s",$p_counter); #update counter
                my $dmsg = sprintf "* removing Paused state and setting paused counter to %s seconds [this duration %s sec]\n",$p_counter,$sec;
                &DebugLog($dmsg) if $dmsg;
            }
        }
        my $dmsg = sprintf "* Total Paused duration: " . &durationrr($p_counter) . " [$p_counter seconds]\n" if $p_counter;
        &DebugLog($dmsg) if $dmsg;

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

    # Debug testing XML response from API (using a file)
    # my $test = 1;
    # if ($test) {
    #     open FILE, "< sessions.xml" or die $!;
    #     my $lines = "";
    #     while (<FILE>) { $lines .= $_; }
    #     close FILE;
    #     print $lines;
    #     my $data = XMLin(encode('utf8',$lines),KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
    #     return $data->{'Video'};
    # }

    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $url = "$proto://$server:$port/status/sessions";

    # Generate our HTTP request.
    my ($userAgent, $request, $response);
    $userAgent = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                       });

    $userAgent->timeout(20);
    $userAgent->agent($appname);
    $userAgent->env_proxy();
    $request = HTTP::Request->new(GET => &PMSurl($url));
    $response = $userAgent->request($request);

    if ($response->is_success) {
        my $XML  = $response->decoded_content();

        if ($debug_xml) {
            print "URL: $url\n";
            print "===================================XML CUT=================================================\n";
            print $XML;
            print "===================================XML END=================================================\n";
        }

        my $data = XMLin(encode('utf8',$XML),KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);

        # verify xml results/remove invalid and unwanted items
        my $container = {};
        foreach my $key (keys %{$data->{'Video'}}) {
            my $librarySectionId = $data->{'Video'}->{$key}->{'librarySectionID'};
            next if ( grep { $_ =~ /^$librarySectionId$/i } @{$options{'exclude_library_id'}});
            next if ( grep { $_ =~ /^$librarySectionId$/i } @exclude_library_ids);
            my $libraryKey = $data->{'Video'}->{$key}->{'key'};
            # any extras will contain the key "extraType". I am not sure what types there are as of yet.
            my $isExtra = $data->{'Video'}->{$key}->{'extraType'};
            if (defined($isExtra)) {
                my $dmsg = "Excluding extra type: $isExtra";
                &DebugLog($dmsg) if $dmsg;
            }
            # should we exclude the item? for now this is mainly related to non library content (channels)
            elsif (!excludeContent($libraryKey,$isExtra)) {
                $container->{$key} = $data->{'Video'}->{$key};
            } else {
                my $dmsg = "Excluding non library content: $data->{'Video'}->{$key}->{'title'}";
                &DebugLog($dmsg) if $dmsg;
            }
        }

        # clean results
        return $container;
        #return $data->{'Video'};
    } else {
        my $dmsg = "Failed to get request $url - The result:";
        $dmsg .= $response->decoded_content();
        &DebugLog($dmsg,1) if $dmsg;

        if ($options{debug}) {
            print "\n-----------------------------------DEBUG output----------------------------------\n\n";
            print Dumper($response);
            print "\n---------------------------------END DEBUG output---------------------------------\n\n";
        }
        exit(2);
    }
}

sub PMSToken() {
    my $token = &getDbToken();
    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $url = "$proto://$server:$port";

    # Generate our HTTP request.
    my ($userAgent, $request, $response);
    $userAgent = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                       });
    $userAgent->timeout(10);
    $userAgent->agent($appname);
    $userAgent->env_proxy();
    $request = HTTP::Request->new(GET => $url);
    $request->header('X-Plex-Token' => $token) if $token;
    $response = $userAgent->request($request);

    if ($response->code == 401) {
        $token = &myPlexToken();
        &updateToken($token);
        return $token;
    }
    return $token;
}


sub getSecPaused() {
    my $db_key = shift;
    if ($db_key) {
        my $cmd = "select paused,paused_counter,stopped from processed where session_id = '$db_key'";
        my $sth = $dbh->prepare($cmd);
        $sth->execute or die("Unable to execute query: $dbh->errstr\n");
        my $row = $sth->fetchrow_hashref;
        my $total=0;
        $total=$row->{'paused_counter'} if $row->{'paused_counter'};
        ## subtract current time from paused epoch as it's not yet stopped ( currently paused )
        if (defined($row->{'paused'}) && !$row->{'stopped'}) {
            $total += time()-$row->{'paused'};
        }
        $total = 0 if !$total || $total !~ /\d+/;
        return $total;
    }
}

sub getLastGroupedTime() {
    my $less = shift;
    $less = 0 if !$less;
    my $cmd = "select max(stopped) from grouped";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my @row = $sth->fetchrow_array;
    if ($row[0]) {
        my $result = $row[0];
        return $result-$less if $result-$less > 0;
        return $result;
    }
    return 0;
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


sub updateRatingKeys() {
    # populate the DB keys (new) from the XML record
    #  same logic can be used for other info we need later

    # ORDER of keys must be ratingKey, parent, grandparent ( used in logic for updates )
    my @keys = qw(ratingKey parentRatingKey grandparentRatingKey);
    # for now we will only update OLD records if the ratingKey is missing. Might want to update the logic to verify all keys are there if it's an episode
    my @tables = qw(processed grouped);
    foreach my $table (@tables) {
        my $cmd = "select id,xml," . join(",",@keys) ." from $table where ratingKey is null and xml is not null";
        my $sth = $dbh->prepare($cmd);
        $sth->execute or die("Unable to execute query: $dbh->errstr\n");

        my @batchUpdates;
        while (my $row_hash = $sth->fetchrow_hashref) {
            if (defined($row_hash->{xml})) {
                my $xml_ref = XMLin($row_hash->{xml});
                if (ref($xml_ref)) {
                    my @updates;
                    my $hasUpdates = 0;
                    foreach my $key (@keys) {
                        my $cur = $row_hash->{$key} || 'NULL';
                        my $new = $xml_ref->{$key} || 'NULL';
                        $hasUpdates = 1 if ($cur ne $new);
                        push (@updates,$new);
                    }

                    # push the update to the batch if modified
                    if ($hasUpdates) {
                        push(@updates,$row_hash->{id});
                        push(@batchUpdates,[@updates]);
                    }
                }
            }
        }

        if (@batchUpdates) {
            my $sth = $dbh->prepare("update $table set ratingKey = ?, parentRatingKey = ?, grandparentRatingKey = ? where id = ?");
            $dbh->begin_work;
            foreach my $record (@batchUpdates) {
                my @array = @$record;
                if (scalar @array == 4) {
                    ## hack to set NULL back to a real NULL. DBI requires undef for nulls
                    for (my $i = 0; $i < scalar(@array); $i++) {
                        $array[$i] = undef if (!$array[$i] or $array[$i] =~ /^null$/i);
                    }
                    $sth->execute(@array) or die("Unable to execute query: $dbh->errstr\n");
                }
            }
            $dbh->commit;
        }
    }
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
    #    my $cmd = "select * from processed where notified = 1 and stopped is null";
    my $cmd = "select * from processed where time is not null and stopped is null";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
        $info->{$row_hash->{'session_id'}} = $row_hash;
    }
    return $info;
}

sub GetRecentlyAddedDB() {
    my $limit_days = shift;
    my $cmd = "select * from recently_added";
    $cmd .= " where time > " . (time()-(86400*$limit_days)) if $limit_days;
    my $info = ();
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    while (my $row_hash = $sth->fetchrow_hashref) {
        $info->{$row_hash->{'item_id'}} = $row_hash;
    }
    return $info;
}

sub GetWatched() {
    my $info = ();
    my ($start,$stop,$group_table) = @_;
    my $where;
    $where .= " and time >= $start "     if $start;
    $where .= " and time <= $stop " if $stop;
    ## going forward only include rows with xml -- mainly for my purposes as I didn't relase this to public before I included xml
    ## we don't need notified = 1 here.
    #my $cmd = "select * from processed where notified = 1 and stopped is not null and xml is not null";
    my $cmd = "select * from processed where stopped is not null and xml is not null";
    if ($group_table) {
        $cmd = "select * from grouped where stopped is not null and xml is not null";
    }
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
    my $cmd = "select * from processed where time is not null and stopped is null";
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
        &DebugLog($cmd);
        my $sth = $dbh->prepare($cmd);
        $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    }
}

sub SetStopped() {
    my $db_key = shift;
    my $time = shift;
    if ($db_key) {
        $time = time() if !$time;
        my $sth = $dbh->prepare("update processed set stopped = ?,paused = null,notified = null where id = ?");
        $sth->execute($time,$db_key) or die("Unable to execute query: $dbh->errstr\n");
    }
    ## BUG FIX - remove paused state for any stopped item - this can be removed at a later date (TODO)
    ## fixes in place to account for this anyways. It's just DB cleanup
    my $sth = $dbh->prepare("update processed set paused = null where stopped is not null");
    $sth->execute() or die("Unable to execute query: $dbh->errstr\n");
    &UpdateGroupedTable; ## update the grouped table
}

sub initDB() {
    ## inital columns - id, session_id, time

    my $dbtable = 'processed';
    my $dbh = DBI->connect("dbi:SQLite:dbname=$data_dir/plexWatch.db","","");
    $dbh->do("PRAGMA  journal_mode = WAL");
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
        { 'name' => 'ratingKey', 'definition' => 'integer', },
        { 'name' => 'parentRatingKey', 'definition' => 'integer', },
        { 'name' => 'grandparentRatingKey', 'definition' => 'integer', },
        );

    my @dbidx = (
        { 'name' => 'userIdx', 'table' => 'user', },
        { 'name' => 'timeIdx', 'table' => 'time', },
        { 'name' => 'stoppedIdx', 'table' => 'stopped', },
        { 'name' => 'notifiedIdx', 'table' => 'notified', },
        { 'name' => 'ratingKeyIdx', 'table' => 'ratingKey', },
        { 'name' => 'parentRatingKeyIdx', 'table' => 'parentRatingKey', },
        { 'name' => 'grandparentRatingKeyIdx', 'table' => 'grandparentRatingKey', },
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
        if ($dbcol_exists{$col->{'name'}} && $dbcol_exists{$col->{'name'}} ne $col->{'definition'}) {       $alter_def =1;  }
    }

    if ($alter_def) {
        my $dmsg = "New Table definitions.. upgrading DB";
        &DebugLog($dmsg,1) if $dmsg;

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
            $dmsg = "Could not upgrade table definitions - Transaction aborted because $@";
            &DebugLog($dmsg,1) if $dmsg;
            eval { $dbh->rollback };
        }
        $dmsg = "DB update DONE\n";
        &DebugLog($dmsg,1) if $dmsg;
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

    &DB_ra_table($dbh);       ## verify/create RecentlyAdded table
    &DB_grouped_table($dbh);  ## verify/create grouped
    &DB_config_table($dbh);   ## verify/create config table
    &DB_auth_table($dbh);   ## verify/create config table

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
        { 'name' => 'EMAIL', 'definition' => 'INTEGER',},
        { 'name' => 'pushover', 'definition' => 'INTEGER',},
        { 'name' => 'pushbullet', 'definition' => 'INTEGER',},
        { 'name' => 'pushalot', 'definition' => 'INTEGER',},
        { 'name' => 'boxcar', 'definition' => 'INTEGER',},
        { 'name' => 'boxcar_v2', 'definition' => 'INTEGER',},

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
        if ($dbcol_exists{$col->{'name'}} && $dbcol_exists{$col->{'name'}} ne $col->{'definition'}) {       $alter_def =1;  }
    }

    if ($alter_def) {
        my $dmsg = "New Table definitions.. upgrading DB";
        &DebugLog($dmsg,1) if $dmsg;

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
            $dmsg = "Could not upgrade table definitions - Transaction aborted because $@";
            &DebugLog($dmsg,1) if $dmsg;
            eval { $dbh->rollback };
        }
        $dmsg = "DB update DONE";
        &DebugLog($dmsg,1) if $dmsg;
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

sub DB_grouped_table() {
    ## verify Recnetly Added table
    my $dbh = shift;
    my $dbtable = 'grouped';
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my $created = 0;
    #ALTER TABLE Name ADD COLUMN new_column INTEGER DEFAULT 0
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) { }
    else {
        my $cmd = "CREATE TABLE $dbtable (id INTEGER PRIMARY KEY );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
        $created = 1;
    }

    ## Add new columns/indexes on the fly  -- and change definitions
    my @dbcol = (
        { 'name' => 'session_id', 'definition' => 'text', },
        { 'name' => 'time', 'definition' => 'timestamp', },
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
        { 'name' => 'ratingKey', 'definition' => 'integer', },
        { 'name' => 'parentRatingKey', 'definition' => 'integer', },
        { 'name' => 'grandparentRatingKey', 'definition' => 'integer', },
        );

    my @dbidx = (
        { 'name' => 'GuserIdx', 'table' => 'user', },
        { 'name' => 'GtimeIdx', 'table' => 'time', },
        { 'name' => 'GstoppedIdx', 'table' => 'stopped', },
        { 'name' => 'GnotifiedIdx', 'table' => 'notified', },
        { 'name' => 'GratingKeyIdx', 'table' => 'ratingKey', },
        { 'name' => 'GparentRatingKeyIdx', 'table' => 'parentRatingKey', },
        { 'name' => 'GgrandparentRatingKeyIdx', 'table' => 'grandparentRatingKey', },
        );

    &initDBtable($dbh,$dbtable,\@dbcol); ## this will just add the columns if needed ( already created the dbtable)

    ## check definitions
    my %dbcol_exists = ();

    for ( @{ $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)") } ) {
        $dbcol_exists{$_->[1]} = $_->[2];
    };

    ## alter table defintions if needed
    my $alter_def = 0;
    for my $col ( @dbcol ) {
        if ($dbcol_exists{$col->{'name'}} && $dbcol_exists{$col->{'name'}} ne $col->{'definition'}) {       $alter_def =1;  }
    }

    if ($alter_def) {
        my $dmsg = "New Table definitions.. upgrading DB";
        &DebugLog($dmsg,1) if $dmsg;

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
            $dmsg = "Could not upgrade table definitions - Transaction aborted because $@";
            &DebugLog($dmsg,1) if $dmsg;
            eval { $dbh->rollback };
        }
        $dmsg = "DB update DONE";
        &DebugLog($dmsg,1) if $dmsg;
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


sub DB_config_table() {
    ## verify Recnetly Added table
    my $dbh = shift;
    my $dbtable = 'config';
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my $created = 0;
    #ALTER TABLE Name ADD COLUMN new_column INTEGER DEFAULT 0
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) { }
    else {
        my $cmd = "CREATE TABLE $dbtable (id INTEGER PRIMARY KEY );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
        $created = 1;
    }

    ## Add new columns/indexes on the fly  -- and change definitions
    my @dbcol = (
        { 'name' => 'version', 'definition' => 'text', },
        { 'name' => 'json', 'definition' => 'text', },
        { 'name' => 'json_pretty', 'definition' => 'text', },
        { 'name' => 'hash_ref', 'definition' => 'text', },
        );

    &initDBtable($dbh,$dbtable,\@dbcol); ## this will just add the columns if needed ( already created the dbtable)

    ## check definitions
    my %dbcol_exists = ();

    for ( @{ $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)") } ) {
        $dbcol_exists{$_->[1]} = $_->[2];
    };

    ## alter table defintions if needed
    my $alter_def = 0;
    for my $col ( @dbcol ) {
        if ($dbcol_exists{$col->{'name'}} && $dbcol_exists{$col->{'name'}} ne $col->{'definition'}) {       $alter_def =1;  }
    }

    if ($alter_def) {
        my $dmsg = "New Table definitions.. upgrading DB";
        &DebugLog($dmsg,1) if $dmsg;

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
            $dmsg = "Could not upgrade table definitions - Transaction aborted because $@";
            &DebugLog($dmsg,1) if $dmsg;
            eval { $dbh->rollback };
        }
        $dmsg = "DB update DONE";
        &DebugLog($dmsg,1) if $dmsg;
    }

    return $dbh;
}

sub DB_auth_table() {
    ## verify Recnetly Added table
    my $dbh = shift;
    my $dbtable = 'auth';
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my $created = 0;
    #ALTER TABLE Name ADD COLUMN new_column INTEGER DEFAULT 0
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) { }
    else {
        my $cmd = "CREATE TABLE $dbtable (id INTEGER PRIMARY KEY );";
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
        $created = 1;
    }

    ## Add new columns/indexes on the fly  -- and change definitions
    my @dbcol = (
        { 'name' => 'token', 'definition' => 'text', },
        { 'name' => 'user', 'definition' => 'text', },
        { 'name' => 'password', 'definition' => 'text', },
        );

    &initDBtable($dbh,$dbtable,\@dbcol); ## this will just add the columns if needed ( already created the dbtable)

    ## check definitions
    my %dbcol_exists = ();

    for ( @{ $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)") } ) {
        $dbcol_exists{$_->[1]} = $_->[2];
    };

    ## alter table defintions if needed
    my $alter_def = 0;
    for my $col ( @dbcol ) {
        if ($dbcol_exists{$col->{'name'}} && $dbcol_exists{$col->{'name'}} ne $col->{'definition'}) {       $alter_def =1;  }
    }

    if ($alter_def) {
        my $dmsg = "New Table definitions.. upgrading DB";
        &DebugLog($dmsg,1) if $dmsg;

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
            $dmsg = "Could not upgrade table definitions - Transaction aborted because $@";
            &DebugLog($dmsg,1) if $dmsg;
            eval { $dbh->rollback };
        }
        $dmsg = "DB update DONE";
        &DebugLog($dmsg,1) if $dmsg;
    }

    return $dbh;
}


sub initDBtable() {
    my $dbh = shift;
    my $dbtable = shift;
    my $col = shift;
    my @dbcol = @$col;
    my $created = 0;
    my $sth = $dbh->prepare("SELECT name FROM SQLITE_MASTER");
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my %tables;
    while (my @tmp = $sth->fetchrow_array) {    foreach (@tmp) {        $tables{$_} = $_;    }}
    if ($tables{$dbtable}) {    }
    else {
        my $cmd ='';
        $cmd = "CREATE TABLE $dbtable (id INTEGER PRIMARY KEY, session_id text, time timestamp default (strftime('%s', 'now')) );";
        $created = 1;
        my $result_code = $dbh->do($cmd) or die("Unable to prepare execute $cmd: $dbh->errstr\n");
    }

    my %dbcol_exists = ();
    for ( @{ $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)") } ) {     $dbcol_exists{$_->[1]} = $_->[2];     };

    for my $col ( @dbcol ) {
        if (!$dbcol_exists{$col->{'name'}}) {
            if ($debug) { print "ALTER TABLE $dbtable ADD COLUMN $col->{'name'} $col->{'definition'}\n";}
            $dbh->do("ALTER TABLE $dbtable ADD COLUMN $col->{'name'} $col->{'definition'}");
        }
    }
    return $created;
}

sub NotifyTwitter() {
    my $provider = 'twitter';

    if ($provider_452->{$provider}) {
        my $dmsg = uc($provider) . " 452: backing off";
        &DebugLog($dmsg,1) if $dmsg;
        return 0;
    }
    my %tw = %{$notify->{'twitter'}};

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    my $url = $alert_options->{'url'} if $alert_options->{'url'};

    my $prefix = '{user}';
    $prefix = $tw{'title'} if $tw{'title'};
    $prefix = '{user}' if $prefix eq $appname; ## force {user} if people still use $appname in config -- forcing update with the need to modify config.

    if ($prefix =~ /\{.*\}/) {
        my $regex = join "|", keys %{$alert_options};
        $regex = qr/$regex/;
        $prefix =~ s/{($regex)}/$alert_options->{$1}/g;
        $prefix =~ s/{\w+}//g; ## remove any {word} - templates that failed
        #$prefix = $appname if !$prefix; ## replace appname if empty, let's conserve space
    }
    $prefix .= ' ' . $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};
    $prefix .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

    $prefix =~ s/\s+$//g if $prefix;
    $alert = $prefix . ': ' . $alert if $prefix;

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

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key        => $tw{'consumer_key'},
        consumer_secret     => $tw{'consumer_secret'},
        access_token        => $tw{'access_token'},
        access_token_secret => $tw{'access_token_secret'},
        ssl                 => 1,
        apiurl              => "https://api.twitter.com/1.1",
        );

    my $result = eval { $nt->update($alert); };

    ## try one more time..
    if ( my $err = $@ ) {
        ## my $rl = $nt->rate_limit_status; not useful for writes atm
        # twitter API doesn't publish limits for writes -- we will use this section to try again if they ever do.
        # if ($err->code == 403 && $rl->{'resources'}->{'application'}->{'/application/rate_limit_status'}->{'remaining'} > 1) {
        if ($err->code == 403) {
            # Grabs the specific Twitter Error code and Message.
            my $twitter_error = $err->{'twitter_error'}->{'errors'}[0]->{'message'};
            my $twitter_code = $err->{'twitter_error'}->{'errors'}[0]->{'code'};
            my $send_msg = '- (You are over the daily limit for sending Tweets. Please wait a few hours and try again.) -- setting $provider to back off additional notifications';
            $provider_452->{$provider} = 1;
            ## Not a Rate Limit Error. We can now add more error codes as we see fit.
            if ($twitter_code == 187) {
                ## TODO: We probably want to just mark this as notified, to move on -- since it's a duplicate
                $send_msg = "Status is a duplicate msg ($twitter_code). Setting $provider to back off additional notifications";
            }
            my $msg452 = uc($provider) . " error 403: $alert - $send_msg";&ConsoleLog($msg452,,1);
            if ($debug)
            {
                warn "HTTP Response Code: ", $err-> code, "\n",
                "HTTP Message......: ", $err->message, "\n",
                "Twitter error.....: ", $twitter_code, "\n",
                "Twitter message...: ", $twitter_error, "\n";
            }
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

    my $dmsg = uc($provider) . " Notification successfully posted.\n" if $debug;
    &DebugLog($dmsg) if $dmsg && $debug;
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
    $prowl{'event'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

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

    # Prowl required UTF8
    $prowl{'application'} = encode('utf8',$prowl{'application'}) if eval { encode('UTF-8', $prowl{'application'}); 1 };
    $prowl{'event'} = encode('utf8',$prowl{'event'}) if eval { encode('UTF-8', $prowl{'event'}); 1 };
    $prowl{'notification'} = encode('utf8',$prowl{'notification'}) if eval { encode('UTF-8', $prowl{'notification'}); 1 };

    # URL encode our arguments
    $prowl{'application'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'event'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    $prowl{'notification'} =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;

    # allow line breaks in message/notification
    $prowl{'notification'} =~ s/\%5Cn/\%0d\%0a/g;

    my $providerKeyString = '';

    # Generate our HTTP request.
    my ($userAgent, $request, $response, $requestURL);
    $userAgent = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                       });
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
    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
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
    $po{'title'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

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

    my $dmsg = uc($provider) . " Notification successfully posted.\n" if $debug;
    &DebugLog($dmsg) if $dmsg && $debug;
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

    my %bc = %{$notify->{$provider}};
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
    $bc{'from'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

    if (!$bc{'email'}) {
        my $msg = "FAIL: Please specify an email address for boxcar in config.pl";
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

sub NotifyBoxcar_V2() {
    my $provider = 'boxcar_v2';

    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    if ($provider_452->{$provider}) {
        if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
        return 0;
    }

    my %bc = %{$notify->{$provider}};
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
    $bc{'from'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

    if (!$bc{'access_token'}) {
        my $msg = "FAIL: Please specify an Access Token for boxcar_v2 in config.pl";
        &ConsoleLog($msg);
    } else {
        my $ua      = LWP::UserAgent->new();
        $ua->timeout(20);
        my $url = 'https://new.boxcar.io/api/notifications';
        my $response = $ua->post( $url, [
                                      "user_credentials" => $bc{'access_token'},
                                      "notification[title]"=> $bc{'from'},
                                      "notification[long_message]" => $bc{'message'},
                                      "notification[sound]" => $bc{'sound'},
                                      "notification[source_name]" => "plexWatch",
                                      "notification[icon_url]" => $bc{'icon_url'},  ]);

        if ($response->is_success) {
            print uc($provider) . " Notification successfully posted.\n" if $debug;
            return 1;
        }
    }

    $provider_452->{$provider} = 1;
    my $msg452 = uc($provider) . " failed: $alert - setting $provider to back off additional notifications\n";
    &ConsoleLog($msg452,,1);
    return 0;
}

sub NotifyPushalot() {
    my $provider = 'pushalot';

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    if ($provider_452->{$provider}) {
        if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
        return 0;
    }

    my %pa = %{$notify->{pushalot}};
    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
    $ua->timeout(20);
    $pa{'message'} = $alert;

    ## allow formatting of appname
    $pa{'title'} = '{user}' if $pa{'title'} eq $appname; ## force {user} if people still use $appname in config -- forcing update with the need to modify config.
    my $format = $pa{'title'};


    if ($format =~ /\{.*\}/) {
        my $regex = join "|", keys %{$alert_options};
        $regex = qr/$regex/;
        $pa{'title'} =~ s/{($regex)}/$alert_options->{$1}/g;
        $pa{'title'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
        $pa{'title'} = $appname if !$pa{'title'}; ## replace appname if empty
    }
    $pa{'title'} .= ': ' . $push_type_titles->{$alert_options->{'push_type'}} if $alert_options->{'push_type'};
    $pa{'title'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

    my $response = $ua->post("https://pushalot.com/api/sendmessage", [
                                 "AuthorizationToken" => $pa{'token'},
                                 "Title" => $pa{'title'},
                                 "Body" => $pa{'message'},
                                 "IsImportant" => $pa{'isimportant'},
                                 "IsSilent" => $pa{'issilent'},
                                 "TimeToLive" => $pa{'timetolive'},
                                 "Source" => "plexWatch",
                             ]);

    my $content  = $response->decoded_content();


    if ($content !~ /\"Success\":true/) {
        print STDERR "Failed to post Pushalot notification -- $pa{'message'} result:$content\n";
        $provider_452->{$provider} = 1;
        my $msg452 = uc($provider) . " failed: $alert -  setting $provider to back off additional notifications\n";
        &ConsoleLog($msg452,,1);

        return 0;
    }

    my $dmsg = uc($provider) . " Notification successfully posted.\n" if $debug;
    &DebugLog($dmsg) if $dmsg && $debug;
    return 1;     ## success
}

sub NotifyPushbullet() {
    my $provider = 'pushbullet';

    #my $alert = shift;
    my $info = shift;
    my ($alert) = &formatAlert($info,$provider);

    my $alert_options = shift;

    if ($provider_452->{$provider}) {
        if ($options{'debug'}) { print uc($provider) . " 452: backing off\n"; }
        return 0;
    }

    my %po = %{$notify->{pushbullet}};
    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
    $ua->timeout(20);
    $po{'message'} = $alert;

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
    $po{'title'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

    my $response = $ua->post( "https://$po{'apikey'}\@api.pushbullet.com/v2/pushes", [
                                  "device_iden" => $po{'device'},
                                  "channel_tag" => $po{'channel'},
                                  "type" => 'note',
                                  "title" => $po{'title'},
                                  "body" => $po{'message'},
                              ]);

    if (!$response->is_success) {
        my $content  = $response->decoded_content();
        print STDERR "Failed to post Pushbullet notification -- $po{'message'} result:$content\n";
        $provider_452->{$provider} = 1;
        my $msg452 = uc($provider) . " failed: $alert -  setting $provider to back off additional notifications\n";
        &ConsoleLog($msg452,,1);

        return 0;
    }

    my $dmsg = uc($provider) . " Notification successfully posted.\n" if $debug;
    &DebugLog($dmsg) if $dmsg && $debug;
    return 1;     ## success
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
        $gntp{'title'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};

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

            # GNTP required UTF8
            $gntp{'title'} = encode('utf8',$gntp{'title'}) if eval { encode('UTF-8', $gntp{'title'}); 1 };
            $alert = encode('utf8',$alert) if eval { encode('UTF-8', $alert); 1 };

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

        # do not send message if body is empty or too small
        if (length($alert) < 5) {
            my $msg452 = uc($provider) . " 452: body of message is empty? body: $alert";
            &DebugLog($msg452,0);
            return 0;
        }

        my %email = %{$notify->{EMAIL}->{$k}};
        $email{'message'} = $alert;

        $email{'subject'} = '{user}' if !$email{'subject'};

        ## allow formatting of appname

        $email{'subject'} =~ s/{push_title}/$push_type_titles->{$alert_options->{'push_type'}}/g if $alert_options->{'push_type'};
        $email{'subject'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};
        if ($email{'subject'} =~ /\{.*\}/) {
            my $regex = join "|", keys %{$alert_options};
            $regex = qr/$regex/;
            $email{'subject'} =~ s/{($regex)}/$alert_options->{$1}/g;
            $email{'subject'} =~ s/{\w+}//g; ## remove any {word} - templates that failed
            $email{'subject'} = $appname if !$email{'subject'}; ## replace appname if empty
            $email{'subject'} = $email{'subject'} . ' ';
        }

        # Subject needs to be decoded (body will be sent as UTF8 encoded)
        if (ref($info) && !$info->{'decoded'}) {
            $email{'subject'} = decode('utf8',$email{'subject'}) if eval { decode('UTF-8', $email{'subject'}); 1 };
        }

        if (!$email{'server'} || !$email{'port'} || !$email{'from'} || !$email{'to'} ) {
            my $msg = "FAIL: Please specify a server, port, to and from address for $provider [$k] in config.pl";
            &DebugLog($msg,1);
        } else {
            # Configure smtp server - required one time only
            # Eval SMTP server - catch errors
            eval {

                #delete_package 'diagnostics';
                #diagnostics->import();
                ## Windows use Net::SMTPS ( supports SSL, TLS and none )
                ## errors do NOT croak, so we will have to catch them and die
                my $SSLmode = 'none';
                $SSLmode = 'starttls' if $email{'port'} == 587 || $email{'enable_tls'};
                $SSLmode = 'ssl'      if $email{'port'} == 465;
                my $mailer = new Net::SMTPS(
                    $email{'server'},
                    ( $email{'server'} ? (Hello => $email{'server'}) : () ),
                    ( $email{'port'} ? (Port => $email{'port'}) : () ),
                    doSSL => $SSLmode,
                    SSL_verify_mode => SSL_VERIFY_NONE,
                    );

                $mailer->auth( $email{'username'}, $email{'password'}) if  $email{'username'} &&  $email{'password'};
                $mailer->mail($email{'from'});
                if ($mailer->to($email{'to'})) {
                    $mailer->data;
                    $mailer->datasend("MIME-Version: 1.0\n");
                    $mailer->datasend("Content-Transfer-Encoding: 8bit\n");
                    $mailer->datasend("Content-Type:text/plain; charset=utf-8\n");
                    $mailer->datasend("X-Mailer: plexWatch\r\n");
                    $mailer->datasend("To: $email{'to'}\r\n");
                    $mailer->datasend("From: $email{'from'}\r\n");
                    $mailer->datasend("Subject: $email{'subject'}\r\n");
                    $mailer->datasend("\r\n");
                    $mailer->datasend($email{'message'});
                    $mailer->datasend("\r\n");
                    $mailer->dataend;
                    $mailer->quit;
                } else {
                    die($mailer->message);
                }
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
    $growl{'title'} .= ' ' . ucfirst($alert_options->{'item_type'}) if $alert_options->{'item_type'};
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
    my $console = shift;
    $console =~ s/\n\n/\n/g;
    $console =~ s/\n/,/g;
    $console =~ s/,$//; # get rid of last comma
    #$console = decode('utf8',$console) if eval { decode('UTF-8', $console); 1 };
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

    # ljunkie (2013-02-10) -- DO NOT re-encode to utf8 ( we already expect utf8)
    # my $vid = XMLin(encode('utf8',$hash),KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video'];)
    my $vid = XMLin($hash,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);


    ## paused or playing? stopped is forced and required from ntype
    my $state = 'unknown';
    if ($ntype =~ /watched|stop/) {
        $state = 'stopped';
    } else {
        $state =  $vid->{Player}->{'state'} if $vid->{Player}->{state};
        $state =  'playing' if $state =~ /buffering/i;
    }


    my $ma_id = '';
    $ma_id = $vid->{Player}->{'machineIdentifier'} if $vid->{Player}->{'machineIdentifier'};
    my $ratingKey = $vid->{'ratingKey'} if $vid->{'ratingKey'};
    my $parentRatingKey = $vid->{'parentRatingKey'} if $vid->{'parentRatingKey'};
    my $grandparentRatingKey = $vid->{'grandparentRatingKey'} if $vid->{'grandparentRatingKey'};

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
    my $streamTypeExtended = 'Direct Play';
    if (ref $vid->{TranscodeSession}) {
        $isTranscoded = 1;
        $transInfo = $vid->{TranscodeSession};
        $streamType = 'T';
        $streamTypeExtended = "Audio:" . $vid->{TranscodeSession}->{'audioDecision'} . " Video:" . $vid->{TranscodeSession}->{'videoDecision'};
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
        if ($percent_complete >= 90) {$percent_complete = 100;    }
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
            if ($percent_complete >= 90) {$percent_complete = 100;    }
        }
    }
    $percent_complete = 0 if !$percent_complete;

    my ($rating,$year,$summary,$extra_title,$genre,$platform,$title,$episode,$season);
    $rating = $year = $summary = $extra_title = $genre = $platform = $title = $episode = $season = '';

    $title = $vid->{title};

    ## Platform title (client device)
    ## prefer title over platform if exists ( seem to have the exact same info of platform with useful extras )
    if ($vid->{Player}->{title}) {$platform =  $vid->{Player}->{title};    }
    elsif ($vid->{Player}->{platform}) {$platform = $vid->{Player}->{platform};    }

    ## length of the video
    my $length;
    $length = sprintf("%.0f",$vid->{duration}/1000) if $vid->{duration};
    $length = &durationrr($length);

    my $orig_user = (split('\@',$vid->{User}->{title}))[0]     if $vid->{User}->{title};
    if (!$orig_user) {$orig_user = 'Local';        }

    my $userID = $vid->{User}->{id};
    $userID = 'Local' if !$userID;

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
    ### to fix.. multiple genres
    ##if (defined($vid->{Genre})) {    $title .= ' ['.$vid->{Genre}->{tag}.']';}
    #$title .= ' ['.$year.']';
    #$title .= ' ['.$rating.']';
    #   }

    my ($user,$tmp) = &FriendlyName($orig_user,$platform);
    # DO NOT decode/encode user

    ## ADD keys here when needed for &Notify hash
    my $info = {
        'user' => $user,
        'userID' => $userID,
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
        'streamtype_extended' => $streamTypeExtended,
        'transInfo' => $transInfo,
        'machineIdentifier' => $ma_id,
        'ratingKey' => $ratingKey,
        'parentRatingKey' => $parentRatingKey,
        'grandparentRatingKey' => $grandparentRatingKey,
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
        $alerts->{'test'}->{'alert'} = "Title [PG-13] [2013] 108min";
        $alerts->{'test'}->{'item_type'} = "Movie";
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
        my $episodeString = "";
        my $seasonString = "";
        if ($info->{'episode'}) {
            if ($info->{'episode'} < 10) { $info->{'episode'} = 0 . $info->{'episode'};}
            $episodeString = "e" . $info->{'episode'};
        }
        if ($info->{'season'}) {
            if ($info->{'season'} < 10) { $info->{'season'} = 0 . $info->{'season'}; }
            $seasonString = "s" . $info->{'season'};
        }
        $info->{'title'} = $data->{'grandparentTitle'} . ': '.  $data->{'title'} . ' ' . $seasonString . $episodeString;
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

    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
    $ua->timeout(20);

    my $sections = ();
    my $url = $host . '/library/sections';
    my $response = $ua->get( &PMSurl($url) );
    if ( ! $response->is_success ) {
        print "Failed to get Library Sections from $url\n";
        exit(2);
    } else {
        my $content  = $response->decoded_content();
        if ($debug_xml) {
            print "URL: $url\n";
            print "===================================XML CUT=================================================\n";
            print $content;
            print "===================================XML END=================================================\n";
        }
        my $data = XMLin(encode('utf8',$content));
        foreach  my $k (keys %{$data->{'Directory'}}) {
            next if ( grep { $_ =~ /^$k$/i } @{$options{'exclude_library_id'}});
            next if ( grep { $_ =~ /^$k$/i } @exclude_library_ids);
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

    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
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
        my $content  = $response->decoded_content();
        if ($debug_xml) {
            print "URL: $url\n";
            print "===================================XML CUT=================================================\n";
            print $content;
            print "===================================XML END=================================================\n";
        }

        #my $vid = XMLin($hash,KeyAttr => { Video => 'sessionKey' }, ForceArray => ['Video']);
        #my $data = XMLin($content, KeyAttr => { Role => ''} );
        my $data = XMLin(encode('utf8',$content));
        return $data->{'Video'} if $data->{'Video'};
    }
}

sub GetRecentlyAdded() {
    my $section = shift; ## array ref &GetRecentlyAdded([5,6,7]);
    my $hkey = shift;    ## array ref &GetRecentlyAdded([5,6,7]);

    my $proto = 'http';
    $proto = 'https' if $port == 32443;
    my $host = "$proto://$server:$port";

    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
    $ua->timeout(20);

    my $info = ();
    my %result;
    # /library/recentlyAdded <-- all sections
    # /library/sections/6/recentlyAdded <-- specific sectoin

    foreach my $section (@$section) {
        my $url = $host . '/library/sections/'.$section.'/recentlyAdded';
        ## limit the output to the last 25 added.
        $url .= '?X-Plex-Container-Start=0&X-Plex-Container-Size=25';
        my $response = $ua->get( &PMSurl($url) );
        if ( ! $response->is_success ) {
            print "Failed to get Library Sections from $url\n";
            exit(2);
        } else {
            my $content  = $response->decoded_content();

            if ($debug_xml) {
                print "URL: $url\n";
                print "===================================XML CUT=================================================\n";
                print $content;
                print "===================================XML END=================================================\n";
            }

            my $data = XMLin(encode('utf8',$content), ForceArray => ['Video']);
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
        $alert_options->{'item_type'} = $alerts->{$k}->{'item_type'};

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
        boxcar_v2 => \&NotifyBoxcar_V2,
        pushbullet => \&NotifyPushbullet,
        pushalot => \&NotifyPushalot,
        file => \&NotifyFile,
        GNTP => \&NotifyGNTP,
        EMAIL => \&NotifyEMAIL,
        external => \&NotifyExternal,
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
    my $forceBackup = shift;
    my $skipFullUpdate = shift;
    ## this will Auto Backup the sql lite db to $data_dir/db_backups/...
    ## --backup will for a daily backup

    # Override in config.pl with

    #$backup_opts = {
    #   'daily' => {
    #       'enabled' => 0,
    #       'keep' => 2,
    #   },
    #   'monthly' => {
    #       'enabled' => 1,
    #       'keep' => 4,
    #   },
    #   'weekly' => {
    #       'enabled' => 1,
    #       'keep' => 4,
    #   },
    #   };

    my $did_backup = 0;
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
        if ($type =~ /daily/ && defined($forceBackup)) {
            print "\n** Forcing a daily backups now\n";
            $options{'backup'} = 1;
        } elsif ($type =~ /daily/ && $options{'backup'}) {
            print "\n** Daily Backups are not enabled -- but you called --backup, forcing backup now..\n";
        } else {
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
            $did_backup = 1; # just set if we backed up any DB
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
            print "\t* Creating backup file now: $file ... " if $debug || $options{'backup'};
            $dbh->sqlite_backup_to_file($file);
            print "DONE\n\n" if $debug || $options{'backup'};
        }

    }

    if ($did_backup && undef($skipFullUpdate)) {
        ## TODO - this won't work if someone disabled backups. ( why disable backups though!)
        print "\n* Updating the grouped table... (this may take a few minutes)\n";
        &UpdateGroupedTable(2); # force a rebuild of the grouped table (daily)
    }

    ## exit if --backup was called.. DO NOT exit if we force the backup
    exit if $options{'backup'} && undef($forceBackup);
}

sub myPlexToken() {
    if (!$myPlex_user || !$myPlex_pass) {
        print "* You MUST specify a myPlex_user and myPlex_pass in the config.pl\n";
        print "\n \$myPlex_user = 'your username'\n";
        print " \$myPlex_pass = 'your password'\n\n";
        exit;
    }
    my $ua = LWP::UserAgent->new(  ssl_opts => {
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE,
                                   });
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
        my $content = $response->decoded_content();
        if ($debug_xml) {
            print "URL: $url\n";
            print "===================================XML CUT=================================================\n";
            print $content;
            print "===================================XML END=================================================\n";
        }
        my $data = XMLin(encode('utf8',$content));
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

sub UpdateGroupedTable() {
    my $tmp = shift;
    my $option = 1;
    $option = $tmp if $tmp;
    # 1 :  Process any new watched content ( for the current 2 days ) into the grouped table
    # 2 :  Truncate grouped, processed all watched content to the DB
    &Watched($option);
}

sub ShowWatched() {
    &Watched();
}

sub Watched() {
    ## TODO -- if this is NOT a update_grouped_table, then we should select from the grouped table for printing -- it will be much faster
    my $update_grouped_table = shift;

    if ($options{'watched'} || $options{'stats'} || $update_grouped_table) {
        my $print_stmt;
        my $stop = time();
        my ($start,$limit_start,$limit_end);

        if ($options{start}) {
            my $v = $options{start};
            my $now = time();

            ## TODO - implememnt parsedate for windows
            if ($^O ne 'MSWin32') {
                $now = parsedate('today at midnight', FUZZY=>1)     if ($v !~ /now/i);
                if ($start = parsedate($v, FUZZY=>1, NOW => $now)) {        $limit_start = localtime($start);   }
            }
        }

        if ($options{stop}) {
            my $v = $options{stop};
            my $now = time();

            ## TODO - implememnt parsedate for windows
            if ($^O ne 'MSWin32') {
                $now = parsedate('today at midnight', FUZZY=>1) if ($v !~ /now/i);
                if ($stop = parsedate($v, FUZZY=>1, NOW => $now)) {     $limit_end = localtime($stop);  }
            }
        }

        if ($update_grouped_table) {
            ## skip limit if we have called for a full refresh (2)
            if ($update_grouped_table != 2) {
                $start = &getLastGroupedTime(86400*2); ## just to be safe, we will process the last two days. It's still very quick
                $stop = time();
                $limit_start = localtime($start);
                $limit_end = localtime($stop);
            }
        } else {
            &UpdateGroupedTable;
        }


        my $is_watched;
        my $FromGroupTable = 1;
        if ($update_grouped_table || $options{'nogrouping'}) {
            ## get watched from processed table (original)
            $FromGroupTable = 0;
        }
        $is_watched = &GetWatched($start,$stop,$FromGroupTable);

        ## already watched.

        if ($options{'watched'}) {
            $print_stmt .= sprintf ("\n======================================== %s ========================================\n",'Watched');
        }
        $print_stmt .= "\nDate Range: ";
        if ($limit_start) { $print_stmt .= $limit_start;    }
        else {  $print_stmt .= "Anytime";    }
        $print_stmt .= ' through ';

        if ($limit_end) {   $print_stmt .= $limit_end;    }
        else {  $print_stmt .= "Now";    }
        $print_stmt .= "\n"; ## clear any print_stmt now


        print $print_stmt if !$update_grouped_table; #print output if we are not updating the table ( job )

        my %seen = ();
        my %seen_epoch = ();
        my %seen_cur = ();
        my %seen_user = ();
        my %stats = ();
        my $ntype = 'watched';
        my %seenc = (); ## testing
        if (keys %{$is_watched}) {
            $print_stmt = ""; #clear the print

            ## sort by the friendly name+device if exists for output
            if (!$update_grouped_table) {
                foreach my $k (sort keys %{$is_watched}) {
                    my ($user,$orig_user) = &FriendlyName($is_watched->{$k}->{user},$is_watched->{$k}->{platform});
                    $is_watched->{$k}->{user} = $user;
                    $is_watched->{$k}->{orig_user} = $orig_user;

                    $is_watched->{$k}->{'encoded'} = 0;
                    if ($user ne $orig_user) {
                        $is_watched->{$k}->{user_enc} = encode('utf8', $user) if eval { encode('UTF-8', $user); 1 };
                        $is_watched->{$k}->{'encoded'} = 1;
                    } elsif  ($is_watched->{$k}->{time} > 1392090762) {
                        # everything after 2013-02-11 is not encoded properly ( excluding above which is special )
                        $is_watched->{$k}->{'encoded'} = 2;
                    }

                }
            }

            foreach my $k (sort {$is_watched->{$a}->{user} cmp $is_watched->{$b}->{'user'} ||
                                     $is_watched->{$a}->{time} cmp $is_watched->{$b}->{'time'} } (keys %{$is_watched}) ) {
                ## use display name
                my $user = $is_watched->{$k}->{user};
                my $orig_user = $is_watched->{$k}->{orig_user};

                if ($update_grouped_table) {
                    ($user,$orig_user) = &FriendlyName($is_watched->{$k}->{user},$is_watched->{$k}->{platform});
                }


                my $skip = 0;
                # Only SKIP user for display purposes. Do not skip user when updating the grouped table
                if (!$update_grouped_table) {
                    $skip = 1;
                    ## skip/exclude users --user/--exclude_user

                    next if ( grep { $_ =~ /$is_watched->{$k}->{'user'}/i } @{$options{'exclude_user'}});
                    next if ( $user  && grep { $_ =~ /^$user$/i } @{$options{'exclude_user'}});
                    # encoded user
                    if ($is_watched->{$k}->{'user_enc'}) {
                        next if ( grep { $_ =~ /$is_watched->{$k}->{'user_enc'}/i } @{$options{'exclude_user'}});
                    }

                    if ($options{'user'}) {
                        # ghetto I know, I have to deal with some old data
                        # needs cleanup -- but old data in the wrong format is the issue.. backwards compatiblity
                        # I just wish perl had a way to detect unicode for sure
                        my $include = $options{'user'};
                        $skip = 0 if $user =~ /^$include$/i; ## user display (friendly) matches specified
                        $skip = 0 if $orig_user =~ /^$include$/i; ## user (non friendly) matches specified

                        $include  = decode('utf8', $options{'user'}) if eval { decode('UTF-8', $options{'user'}); 1 };
                        $skip = 0 if $user =~ /^$include$/i; ## user display (friendly) matches specified
                        $skip = 0 if $orig_user =~ /^$include$/i; ## user (non friendly) matches specified

                        $include  = encode('utf8', $options{'user'}) if eval { encode('UTF-8', $options{'user'}); 1 };
                        $skip = 0 if $user =~ /^$include$/i; ## user display (friendly) matches specified
                        $skip = 0 if $orig_user =~ /^$include$/i; ## user (non friendly) matches specified
                    }  else {   $skip = 0;    }
                }
                next if $skip;

                ## only show one watched status on movie/show per day (default) -- duration will be calculated from start/stop on each watch/resume
                ## --nogrouping will display movie as many times as it has been started on the same day.

                ## to cleanup - maybe subroutine
                my ($sec, $min, $hour, $day,$month,$year) = (localtime($is_watched->{$k}->{time}))[0,1,2,3,4,5];
                my $serial = timelocal(0, 0, 0, $day, $month, $year);
                $year += 1900;
                $month += 1;
                ## TODO - implememnt parsedate for windows
                #my $serial = "$year$month$day";
                # I can probably get rid of this since the serial above works for both
                if ($^O ne 'MSWin32') {
                    $serial = parsedate("$year-$month-$day 00:00:00");
                }
                #my $skey = $is_watched->{$k}->{user}.$year.$month.$day.$is_watched->{$k}->{title};
                my $skey = $user.$year.$month.$day.$is_watched->{$k}->{title};

                ## get previous day -- see if video same title was watched then -- if so -- group them together for display purposes. stats and --nogrouping will still show the break
                my ($sec2, $min2, $hour2, $day2,$month2,$year2) = (localtime($is_watched->{$k}->{time}-86400))[0,1,2,3,4,5];
                $year2 += 1900;
                $month2 += 1;


                #my $skey2 = $is_watched->{$k}->{user}.$year2.$month2.$day2.$is_watched->{$k}->{title};
                my $skey2 = $user.$year2.$month2.$day2.$is_watched->{$k}->{title};
                if ($seen{$skey2}) {        $skey = $skey2;     }

                my $orig_skey = $skey; ## DO NOT MODIFY THIS


                ## split lines if start/restart > $watched_grouping_maxhr
                #    * do not just blindly group by day.. the start/restart should be NO MORE than a few hours apart ($watched_grouping_maxhr)
                $skey = $seen_cur{$orig_skey}  if $seen_cur{$orig_skey};                 ## if we have set $seen_cur - reset skey to that
                $seen_epoch{$skey} = $is_watched->{$k}->{time}  if !$seen_epoch{$skey};  ## set epoch for skey (if not set)
                my $diff = $is_watched->{$k}->{time}-$seen_epoch{$skey};                 ## diff between last start and this start

                if ($diff > (60*60)*($watched_grouping_maxhr)) {
                    my $d_out = &durationrr($diff) .
                        " between start,restart of '$is_watched->{$k}->{title}' for $user on $year-$month-$day: starting a new line\n";
                    &DebugLog($d_out) if !$update_grouped_table;
                    $skey = $orig_skey . $is_watched->{$k}->{time}; ## increment the skey
                    $seen_cur{$orig_skey} = $skey;                  ## set what the skey will be for future
                }
                $seen_epoch{$skey} = $is_watched->{$k}->{time};  ## set the last epoch seen for this skey
                ## END split if > $watched_grouping_maxhr

                ## stat -- quick and dirty -- to clean up later
                $stats{$user}->{'total_duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
                $stats{$user}->{'duration'}->{$serial} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
                ## end

                next if !$options{'watched'} && !$update_grouped_table;
                next if $is_watched->{$k}->{xml} =~ /<opt><\/opt>/i; ## bug -- fixed in 0.0.19

                my $paused;
                if ($FromGroupTable == 1) {
                    ## pulling from the grouped table - no need to dynamically update the paused counter this time
                    $paused = $is_watched->{$k}->{paused_counter};
                } else {
                    ## used to dynamically get the paused counter if the content hasn't been stopped yet
                    ## or return the paused time if already stopped
                    $paused = &getSecPaused($k);
                }

                my $time2 = localtime ($is_watched->{$k}->{time} );

                ## grouping table is now available.. no need to go through logic if we are just printing
                ## i.e. we use the raw db results in either the 'grouped' or 'processed' table
                if (!$update_grouped_table) {
                    if (!$seen_user{$user}) {
                        $seen_user{$user} = 1;
                        # needs cleanup -- but old data in the wrong format is the issue.. backwards compatiblity
                        # I just wish perl had a way to detect unicode for sure
                        if (!$is_watched->{$k}->{'encoded'} or $is_watched->{$k}->{'encoded'} == 2) {
                            $user  = decode('utf8',  $user) if eval { decode('UTF-8',$user); 1 };
                            $orig_user = $user;
                        }
                        $print_stmt .= "\nUser: " . $user;
                        $print_stmt .= ' ['. $orig_user .']' if $user ne $orig_user;
                        $print_stmt .= "\n";
                    }
                    my $time = localtime ($is_watched->{$k}->{time} );
                    my $info = &info_from_xml($is_watched->{$k}->{'xml'},$ntype,$is_watched->{$k}->{'time'},$is_watched->{$k}->{'stopped'},$paused);

                    ## encode the user for output ( only if different -- otherwise we will take what Plex has set)
                    if ($is_watched->{$k}->{'encoded'}) {
                        $info->{'user'} = encode('utf8',  $info->{'user'}) if eval { encode('UTF-8',   $info->{'user'}); 1 };
                    }

                    $info->{'ip_address'} = $is_watched->{$k}->{ip_address};
                    my $alert = &Notify($info,1); ## only return formated alert
                    $print_stmt .= sprintf(" %s: %s\n",$time, $alert);
                }


                ## update the grouped table
                else {
                    if (!$seen{$skey}) {
                        # these field are used for output
                        $seen{$skey}->{'ip_address'} = $is_watched->{$k}->{ip_address};
                        $seen{$skey}->{'time'} = $is_watched->{$k}->{time};
                        $seen{$skey}->{'xml'} = $is_watched->{$k}->{xml};
                        $seen{$skey}->{'user'} = $user;
                        $seen{$skey}->{'orig_user'} = $orig_user;
                        $seen{$skey}->{'stopped'} = $is_watched->{$k}->{stopped};

                        ## These fields are used to update the DB table --  ( some or cruft, but we will keep them the same )
                        ## output will have these too, but we use the info_from_xml for formatting. We want the raw info for the DB
                        if ($update_grouped_table) {
                            #$seen{$skey}->{'ip_address'} = '' if !$seen{$skey}->{'ip_address'};
                            $seen{$skey}->{'ip_address'} = $is_watched->{$k}->{ip_address} || ''; ## special - fields didn't exist in old version
                            $seen{$skey}->{'platform'} = $is_watched->{$k}->{'platform'};
                            $seen{$skey}->{'db_key'} = $k;
                            $seen{$skey}->{'title'} = $is_watched->{$k}->{'title'};
                            $seen{$skey}->{'orig_title'} = $is_watched->{$k}->{'orig_title'};
                            $seen{$skey}->{'orig_title_ep'} = $is_watched->{$k}->{'orig_title_ep'};
                            $seen{$skey}->{'episode'} = $is_watched->{$k}->{'episode'};
                            $seen{$skey}->{'season'} = $is_watched->{$k}->{'season'};
                            $seen{$skey}->{'year'} = $is_watched->{$k}->{'year'};
                            $seen{$skey}->{'rating'} = $is_watched->{$k}->{'rating'};
                            $seen{$skey}->{'genre'} = $is_watched->{$k}->{'genre'};
                            $seen{$skey}->{'summary'} = $is_watched->{$k}->{'summary'};
                            $seen{$skey}->{'ratingKey'} = $is_watched->{$k}->{'ratingKey'};
                            $seen{$skey}->{'parentRatingKey'} = $is_watched->{$k}->{'parentRatingKey'};
                            $seen{$skey}->{'grandparentRatingKey'} = $is_watched->{$k}->{'grandparentRatingKey'};
                            #$seen{$skey}->{'notified'} = $is_watched->{$k}->{'notified'};
                            if (!$seen{$skey}->{'paused'}) {
                                $seen{$skey}->{'paused'} = $paused;
                            } else {
                                $seen{$skey}->{'paused'} = $seen{$skey}->{'paused'}+$paused;
                            }
                        }
                        ## end required db fields

                        if (!$count_paused) {
                            $seen{$skey}->{'duration'} += ($is_watched->{$k}->{stopped}-$is_watched->{$k}->{time})-$paused;
                        } else {
                            $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
                        }

                    } else {
                        ## if same user/same movie/same day -- append duration -- must of been resumed
                        ## tally up paused time, duration and set the stopped time accordingly

                        ## update paused counter
                        if (!$seen{$skey}->{'paused'}) {
                            $seen{$skey}->{'paused'} = $paused;
                        } else {
                            $seen{$skey}->{'paused'} = $seen{$skey}->{'paused'}+$paused;
                        }

                        ## update duration
                        if (!$count_paused) {
                            $seen{$skey}->{'duration'} += ($is_watched->{$k}->{stopped}-$is_watched->{$k}->{time})-$paused;
                        } else {
                            $seen{$skey}->{'duration'} += $is_watched->{$k}->{stopped}-$is_watched->{$k}->{time};
                        }

                        ## update the group with the most recent XML
                        $seen{$skey}->{'xml'} = $is_watched->{$k}->{xml};

                        ## update stopped time
                        # the stopped time is only used for getting the duration ( so it will not be correct in grouped, but that's fine )
                        # stopped time = start time + duration_watched ( minus the paused counter if set in prefs )
                        $seen{$skey}->{'stopped'} =  $seen{$skey}->{'duration'}+$seen{$skey}->{'time'};

                        # Wrong way of getting the stopped time
                        #if ($is_watched->{$k}->{stopped} > $seen{$skey}->{'stopped'}) {
                        #    $seen{$skey}->{'stopped'} = $is_watched->{$k}->{stopped}; ## include max stopped in case someone wants to display it
                        #}

                    }
                }

                ## watched rollover: if the show has been completed and we always start a new grouping after being watched fully, increment the key
                if ($watched_show_completed) {
                    my $paused = &getSecPaused($k);
                    my $info = &info_from_xml($is_watched->{$k}->{'xml'},$ntype,$is_watched->{$k}->{'time'},$is_watched->{$k}->{'stopped'},$paused);
                    if ($info->{'percent_complete'} > 99) {
                        my $d_out = "$is_watched->{$k}->{title} watched 100\% by $user on $year-$month-$day - incrementing seen key\n";
                        $seen_cur{$orig_skey} = $orig_skey . $is_watched->{$k}->{time}; ## increment the skey -- and set for the future keys if we need to append
                        &DebugLog($d_out) if !$update_grouped_table;
                    }
                }
                ## end watched rollover
            }

        }
        else {      $print_stmt .= "\n* nothing watched\n"; }

        ## Grouping Watched TITLE by day - default
        if ($update_grouped_table) {
            &ProcessGrouped(\%seen,$update_grouped_table);
        }

        ## show stats if --stats
        if ($options{stats}) {
            $print_stmt .= sprintf("\n======================================== %s ========================================\n",'Stats');
            foreach my $user (keys %stats) {
                $print_stmt .= sprintf("user: %s's total duration %s \n", $user, duration_exact($stats{$user}->{total_duration}));
                foreach my $epoch (sort keys %{$stats{$user}->{duration}}) {
                    my $h_date;
                    if ($^O eq 'MSWin32') {
                        $h_date = strftime( "%a %b %d %Y", localtime($epoch) );
                    } else {
                        $h_date = strftime "%a %b %e %Y", localtime($epoch);
                    }
                    $print_stmt .= sprintf(" %s: %s %s\n", $h_date, $user, duration_exact($stats{$user}->{duration}->{$epoch}));
                }
                $print_stmt .= "\n";
            }
        }
        $print_stmt .= "\n";
        print $print_stmt if !$update_grouped_table; #print output if we are not updating the table ( job )

    }
}

sub excludeContent() {
    # expected results
    # 0: include
    # 1: exclude

    my $key = shift;
    # if we include library content -- return 0
    return 0 if $inc_non_library_content;
    # include library content ( always )
    return 0 if isLibraryContent($key);
    # exlude other content
    return 1;
}

sub isLibraryContent(){
    my $key = shift;
    ## determined for now based on the items key. It must include "/library".
    return 1 if $key =~ /\/library/i;
    return 0
}

sub checkVersion() {
    my $cmd = "select * from config";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my $row = $sth->fetchrow_hashref;
    my $total=0;
    return $row->{'version'} if $row->{'version'};
    return 0;
}

sub getDbToken() {
    my $cmd = "select token from auth";
    my $sth = $dbh->prepare($cmd);
    $sth->execute or die("Unable to execute query: $dbh->errstr\n");
    my $row = $sth->fetchrow_hashref;
    my $total=0;
    return $row->{'token'} if $row->{'token'};
    return 0;
}

sub updateToken() {
    my $token = shift;
    my $insert = $dbh->prepare("insert into auth (token) values (?)");
    my $delete = $dbh->prepare("DELETE FROM auth");

    $dbh->begin_work;
    $delete->execute;
    $insert->execute($token) or die("Unable to execute query: $dbh->errstr\n");
    # commit changes
    $dbh->commit;
}

sub extrasCleaner() {
    #randomly we might need to clean items. This will be needed to help assist. As of now, we need to clean any "extraType" logged to the processed table.
    my $count = $dbh->prepare("select count(*) as extras from processed where xml like ?");
    $count->execute('%extraType=%') or die("Unable to execute query: $dbh->errstr\n");
    my $row = $count->fetchrow_hashref;
    if ($row->{extras} == 0) {
        print "\n* No \"Extras\" found in the database.\n\n";
        return 0;
    } else {
        print "\n* Backing up DB before removing " . $row->{extras} . " trailers (extras) from plexWatch";
        &BackupSQlite("true","true"); # force a backup

        print "\n* Removing: " . $row->{extras} . " trailers (extras) from plexWatch";
        my $sth = $dbh->prepare("delete from processed where xml like ?");
        $dbh->begin_work;
        $sth->execute('%extraType=%') or die("Unable to execute query: $dbh->errstr\n");
        $dbh->commit;
        if ($sth->rows > 0) {
            print "\n* Removed: " . $sth->rows . " trailers (extras) from plexWatch";
            print "\n* Updating the grouped table... (this may take a few minutes)\n";
            &UpdateGroupedTable(2); # force a rebuild of the grouped table (daily)
            print "\n* DONE!\n";
        }
    }
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

   --recently_added               notify when new movies or shows are added to the plex media server (required: config.pl: push_recentlyadded => 1)
                                      All TV Show Sections : --recently_added=show
                                      All Movie Sections   : --recently_added=movie
                                      Combined Movie/TV    : --recently_added=show,movie
                                      Specific Sections    : --recently_added --id=# --id=#

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

   --clean_extras                 Remove any trailers or extras from the plexWatch DB

   --exclude_library_id=...       Full exclusion for a library section id. It will not log or notify.

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
