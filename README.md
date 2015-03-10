plexWatch - 0.3.2 (2014-11-19)
=========
***Notify*** and Log ***'Now Playing'*** and ***'Watched'*** content from a Plex Media Server + ***'Recently Added'*** (...and more)

[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=CHRZ55VCAJSYG)


** windows and linux codebase has been fully merged **

----------------

### Need Help?
* Linux Forum: http://forums.plexapp.com/index.php/topic/72552-plexwatch-plex-notify-script-send-push-alerts-on-new-sessions-and-stopped/
* Windows Forum: http://forums.plexapp.com/index.php/topic/79616-plexwatch-windows-branch/

### Want a frontend? ***plexWatch/Web***
*  Download: https://github.com/ecleese/plexWatchWeb
*    Forums: http://forums.plexapp.com/index.php/topic/82819-plexwatchweb-a-web-front-end-for-plexwatch/

----------------

### Read More about plexWatch

**Supported Push Notifications**
* Email
* https://pushover.net
* https://prowlapp.com
* http://growl.info/ (via GrowlNotify @ http://growl.info/downloads#generaldownloads)
* https://twitter.com/ (create a new app @ https://dev.twitter.com/apps)
* https://boxcar.io/ & boxcar V2
* https://pushbullet.com
* SNARL/GROWL: GNTP notifications supported. Anything that uses GNTP *should* work
* External Scripts: home automation, pause download clients, etc (rudimentary plugins)

**What it does**
* notify when a user starts watching a video
* notify when a user stops watching a video
* notify when a user pauses watching a video
* notify when a user resumes watching a video
* notify on recently added content to a PMS server
* notifies via email, prowl, pushover, growl, twitter, boxcar, pushbullet, GNTP and/or a log file
* enable/disable notifications per provider & per notification type (start, stop, paush, resume, recently added)
* backed by a SQLite DB (for state and history)
* CLI to query watched videos, videos being watched and stats on time watched per user
* Limit output per user or exclude users
* ...more to come


###Perl Requirements

* LWP::UserAgent
* XML::Simple
* DBI
* Time::Duration;
* Time::ParseDate;
* JSON

#### These should be part of the base Perl install

* Pod::Usage;        (Perl base on rhel/centos)
* Fcntl qw(:flock);  (Perl base)
* Getopt::Long;      (Perl base)
* POSIX qw(strftime) (Perl base)
* File::Basename     (Perl base)


#### Required ONLY if you use twitter

* Net::Twitter::Lite::WithAPIv1_1
* Net::OAuth

```sudo cpan Net::Twitter::Lite```

```sudo cpan Net::OAuth```


#### Required ONLY if you use GNTP

* Growl::GNTP

```sudo cpan Growl::GNTP```


#### Required ONLY if you use Email

* Net::SMTPS

```sudo cpan Net::SMTPS```


#### Required ONLY if 'Client IP Logging' is enable

* File::ReadBackwards

* To enable: edit config.pl

```
$server_log    = '/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log'; ## used to log IP address of user (alpha)
$log_client_ip = 1; ## requires $server_log to be available too.
$debug_logging = 1; ## logs to $data_dir/debug.log ( only really helps debug IP logging for now )
```

```
# Debian/Ubuntu: apt-get
 sudo apt-get install libfile-readbackwards-perl

# Rhel/Centos: yum
 sudo yum install perl\(File::ReadBackwards\)

# Others: cpan
 sudo cpan File::ReadBackwards
```


<br/>

### Install
----

1. Download plexWatch.pl and config.pl-dist to /opt/plexWatch/
    *    WGET

    ```
    sudo wget -P /opt/plexWatch/ https://raw.github.com/ljunkie/plexWatch/master/plexWatch.pl
    sudo wget -P /opt/plexWatch/ https://raw.github.com/ljunkie/plexWatch/master/config.pl-dist
    ````
    *    CURL

    ```
    sudo mkdir -p /opt/plexWatch/
    sudo curl https://raw.github.com/ljunkie/plexWatch/master/plexWatch.pl -o /opt/plexWatch/plexWatch.pl
    sudo curl https://raw.github.com/ljunkie/plexWatch/master/config.pl-dist -o /opt/plexWatch/config.pl-dist
    ```

2. ```sudo chmod 777 /opt/plexWatch && sudo chmod 755 /opt/plexWatch/plexWatch.pl```

3. ```sudo cp /opt/plexWatch/config.pl-dist /opt/plexWatch/config.pl```
    1. ```sudo nano /opt/plexWatch/config.pl```
    * Modify Variables as needed

    ```perl
    $server = 'localhost';   ## IP of PMS - or localhost
    $port   = 32400;         ## port of PMS
    $notify_started = 1;   ## notify when a stream is started (first play)
    $notify_stopped = 1;   ## notify when a stream is stopped
    ```

    ```bash
    $notify = {...
    * to enable a provider, i.e. file, prowl, pushover
    set 'enabled' => 1, under selected provider
    * Prowl     : 'apikey' required
    * Pushover  : 'token' and 'user' required
    * Growl     : 'script' required :: GrowlNotify from http://growl.info/downloads (GNTP replaces this)
    * twitter   : 'consumer_key', 'consumer_secret', 'access_token', 'access_token_secret' required
    * boxcar    : 'email' required
    * pushover  : 'apikey' and 'device' required
    * GNTP      : 'server', 'port' required. 'password' optional. You must allow network notifications on the Growl Server
    ```

4. Install Perl requirements
    * Debian/Ubuntu - apt-get

    ```bash
    apt-get install libwww-perl libxml-simple-perl libtime-duration-perl libtime-modules-perl libdbd-sqlite3-perl perl-doc libjson-perl
    ```
    * RHEL/Centos - yum

    ```bash
    yum -y install perl\(LWP::UserAgent\) perl\(XML::Simple\) perl\(Pod::Usage\) perl\(JSON\)
               perl\(DBI\) perl\(Time::Duration\)  perl\(Time::ParseDate\) perl\(DBD::SQLite\)
    ```

5. **run** the script manually to verify it works: /opt/plexWatch/plexWatch.pl
  * start video(s)
  * ```/opt/plexWatch/plexWatch.pl```
  * stop video(s)
  * ```/opt/plexWatch/plexWatch.pl```


6. setup crontab or launchagent to run the script every minute
    * __linux__: /etc/crontab

    ```bash
    * * * * * YOUR_USERNAME /opt/plexWatch/plexWatch.pl
    ```
    * __OSX__: use a launchagent instead of cron. Refer to the __FAQ__ on the bottom.


7. [*optional*] If you want Recently Added notifiations - setup another crontab or launchagent entry
    * __linux__: /etc/crontab

    ```bash
    */15 * * * * YOUR_USERNAME /opt/plexWatch/plexWatch.pl --recently_added=movie,tv
    ```
    * __OSX__: use a launchagent instead of cron. Refer to the __FAQ__ on the bottom.


<br/>

### Twitter integration
----
If you want to use twitter, you will need to install two more Perl modules

*  requires Net::Twitter::Lite::WithAPIv1_1

    ```bash
    sudo cpan Net::Twitter::Lite::WithAPIv1_1

    # OR force install it
    sudo cpan -f Net::Twitter::Lite::WithAPIv1_1
    ```

*  requires Net::OAuth >= 0.28

    ```bash
    sudo cpan Net::OAuth

    # OR force install it
    sudo cpan -f Net::OAuth
    ```

#### Twitter setup

* create a new app @ https://dev.twitter.com/apps
* click "Create New App"
    * Name: unique name for for your app
    * Description: fill something in...
    * Website: you need some valid website..
    * (read) and accept terms
    * click "Create you Twitter Application"
* click "Modify app permission" under the Details Tab
    * change to Read and Write
    * update settings
* click the "API keys" tab
    * click "create my access token"
    * click "Test OAuth" button to view the required API keys need for config.pl
* Edit the config.pl
    * enable notification for twitter in config.pl
    * enter in the required keys, secrets and tokens


<br/>
### GNTP integration
----
If you want to use GNTP (growl), you will need to install a module

*  requires Growl::GNTP

    ```bash
    sudo cpan Growl::GNTP
    ```
    * Note: CPAN install failed on centos until I installed perl\(Data::UUID\)



<br/>
## Using the script


### Sending Notifications

* Follow the install guide above, and refer to step #5 and #6

* Sending test notifications:

    ```
    /opt/plexWatch/plexWatch.pl --test_notify=start

    /opt/plexWatch/plexWatch.pl --test_notify=stop
    ```

### Getting a list of watched shows

* This will only work for shows this has already notified on.

#####  list all watched shows - no limit

```
/opt/plexWatch/plexWatch.pl --watched
======================================== Watched ========================================
Date Range: Anytime through Now

User: jimbo
 Wed Jun 26 15:56:09 2013: jimbo watched: South Park - A Nightmare on FaceTime [duration: 22 minutes, and 15 seconds]
 Wed Jun 26 20:18:34 2013: jimbo watched: The Following - Whips and Regret [duration: 46 minutes, and 45 seconds]
 Wed Jun 26 20:55:02 2013: jimbo watched: The Following - The Curse [duration: 46 minutes, and 15 seconds]

User: carrie
 Wed Jun 24 08:55:02 2013: carrie watched: The Following - The Curse [duration: 46 minutes, and 25 seconds]
 Wed Jun 26 20:19:48 2013: carrie watched: Dumb and Dumber [1994] [PG-13] [duration: 1 hour, 7 minutes, and 10 seconds]
```

##### list watched shows - limit by TODAY only

```
/opt/plexWatch/plexWatch.pl --watched --start=today --start=tomorrow

======================================== Watched ========================================
Date Range: Fri Jun 28 00:00:00 2013 through Sat Jun 29 00:00:00 2013

User: jimbo
Fri Jun 28 09:18:22 2013: jimbo watched: Married ... with Children - Mr. Empty Pants [duration: 1 hour, 23 minutes, and 20 seconds]
```

##### list watched shows - limit by a start and stop date

```
/opt/plexWatch/plexWatch.pl --watched --start="2 days ago" --stop="1 day ago"

======================================== Watched ========================================
Date Range: Fri Jun 26 00:00:00 2013 through Thu Jun 27 00:00:00 2013

 User: Jimbo
  Wed Jun 26 15:56:09 2013: rarflix watched: South Park - A Nightmare on FaceTime [duration: 22 minutes, and 15 seconds]
  Wed Jun 26 20:18:34 2013: rarflix watched: The Following - Whips and Regret [duration: 46 minutes, and 45 seconds]
  Wed Jun 26 20:55:02 2013: rarflix watched: The Following - The Curse [duration: 46 minutes, and 15 seconds]

 User: Carrie
  Wed Jun 26 20:19:48 2013: Carrie watched: Dumb and Dumber [1994] [PG-13] [duration: 1 hour, 7 minutes, and 10 seconds]
```

#### list watched shows: option --nogrouping vs default

#####  with --nogrouping
```
 Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 27 minutes and 54 seconds]
 Sun Jun 30 15:41:02 2013: exampleUser watched: Your Highness [2011] [R] [duration: 4 minutes and 59 seconds]
 Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 24 minutes and 17 seconds]
 Sun Jun 30 17:48:01 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 1 hour, 44 minutes, and 1 second]
 Sun Jun 30 19:45:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour and 24 minutes]
```

#####  without --nogrouping [default]
```
  Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour, 56 minutes, and 53 seconds]
  Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 2 hours, 8 minutes, and 18 seconds]
```


### Stats - users total watched time with total per day

* --start, --stop, --user options can be supplied to limit the output

```
/opt/plexWatch/plexWatch.pl --stats

Date Range: Anytime through Now

======================================== Stats ========================================

user: Stans's total duration 3 hours and 56 seconds
 Thu Jul 11 2013: Stan 16 minutes and 58 seconds
 Fri Jul 12 2013: Stan 1 hour, 41 minutes, and 59 seconds
 Sat Jul 13 2013: Stan 1 hour, 1 minute, and 59 seconds

 user: Franks's total duration 2 hours, 43 minutes, and 2 seconds
  Thu Jul  4 2013: Frank 57 minutes and 1 second
  Sun Jul 14 2013: Frank 1 hour, 46 minutes, and 1 second
```



<br/>
## Additional options

#### --notify

```
 --user=...                      limit output to a specific user. Must be exact, case-insensitive
 --exclude_user=...              exclude users - you may specify multiple on the same line. '--notify --exclude_user=user1 --exclude_user=user2'
```

#### --stats

```
 --start=...                     limit watched status output to content started AFTER/ON said date/time
 --stop=...                      limit watched status output to content started BEFORE/ON said date/time
 --user=...                      limit output to a specific user. Must be exact, case-insensitive
 --exclude_user=...              exclude users - you may specify multiple on the same line. '--notify --exclude_user=user1 --exclude_user=user2
```
#### --watched

```
 --start=...                     limit watched status output to content started AFTER/ON said date/time
 --stop=...                      limit watched status output to content started BEFORE/ON said date/time
 --nogrouping                    will show same title multiple times if user has watched/resumed title on the same day
 --user=...                      limit output to a specific user. Must be exact, case-insensitive
 --exclude_user=...              exclude users - you may specify multiple on the same line. '--notify --exclude_user=user1 --exclude_user=user2'
```


### Notification format

* You can edit the format of your alerts and cli output or --watching --watched. This can be done  in the config.pl or on the cli

####cli options:
```
 --format_options        : list all available formats for notifications and cli output

 --format_start=".."     : modify start notification :: --format_start='{user} watching {title} on {platform}'

 --format_stop=".."      : modify stop notification :: --format_stop='{user} watched {title} on {platform} for {duration}'

 --format_watched=".."   : modify cli output for --watched  :: --format_watched='{user} watched {title} on {platform} for {duration}'

 --format_watching=".."  : modify cli output for --watching :: --format_watching='{user} watching {title} on {platform}'
```

### Advanced --recently_added options
```
* All Movie Sections : ```./plexWatch.pl --recently_added=movie```

* All Movie / TV Sections : ```./plexWatch.pl --recently_added=movie,show```

* Specific Section(s) : ```./plexWatch.pl --recently_added --id=# --id=#```

```

./plexWatch.exe --recently_added

        * Available Sections:

        ID    Title                Type       Path
        -------------------------------------------------------------------
        8     Concerts             movie      /NFS/Videos/Music
        6     Movies               movie      /NFS/Videos/Film
        17    Holiday Movies       movie      /NFS/Videos/Others/Holiday_Movies
        5     TV Shows             show       /NFS/Videos/TV

        * Usage:

        All Movie Sections    : ./plexWatch.pl --recently_added=movie
        All Movie/TV Sections : ./plexWatch.pl --recently_added=movie,show
        Specific Section(s)   : ./plexWatch.pl --recently_added --id=# --id=#
```


####config.pl options

```perl
$alert_format = {
      'start'    =>  '{user} watching {title} [{streamtype}] [{year}] [{rating}] on {platform} [{progress} in]',
      'stop'     =>  '{user} watched {title} [{streamtype}] [{year}] [{rating}] on {platform} for {duration} [{percent_complete}%]',
      'watched'  =>  '{user} watched {title} [{streamtype}] [{year}] [{length}] [{rating}] on {platform} for {duration} [{percent_complete}%]',
      'watching' =>  '{user} watching {title} [{streamtype}] [{year}] [{rating}] [{length}] on {platform} [{time_left} left]'
	      };

```


####Format options Help
```
/opt/plexWatch/plexWatch.pl --format_options
Format Options for alerts

     --start='{user} watching {title} [{streamtype}] [{year}] [{rating}] on {platform} [{progress} in]'
     --stop='{user} watched {title} [{streamtype}] [{year}] [{rating}] on {platform} for {duration} [{percent_complete}%]'
     --watched='{user} watched {title} [{streamtype}] [{year}] [{length}] [{rating}] on {platform} for {duration} [{percent_complete}%]'
     --watching='{user} watching {title} [{streamtype}] [{year}] [{rating}] [{length}] on {platform} [{time_left} left]'

     {percent_complete} Percent of video watched -- user could have only watched 5 minutes, but skipped to end = 100%
                {state} playing, paused or buffering [ or stopped ] (useful on --watching)
               {rating} rating of video - TV-MA, R, PG-13, etc
              {summary} summary or video
           {streamtype} T or D - for Transcoded or Direct
                 {user} user
            {time_left} progress of video [only available/correct on --watching and stop events]
             {platform} client platform
           {transcoded} 1 or 0 - if transcoded
            {orig_user} orig_user
             {progress} progress of video [only available/correct on --watching and stop events]
             {duration} duration watched
               {length} length of video
            {stop_time} stop_time
                {title} title
          {start_start} start_time
                 {year} year of video

```



<br/>
## Advanced options - config.pl

#### Grouping of watched shows

```
$watched_show_completed = 1; always show completed show/movie as it's own line (default 1)
```

```
$watched_grouping_maxhr = 2; do not group shows together if start/restart is > X hours (default is 3 hours)
```

#### SQLite backups

By default this script will automatically backup the SQLite db to: $data_dir/db_backups/ ( normally: /opt/plexWatch/db_backups/ )

* you can force a Daily backup with --backup

It will keep 2 x Daily , 4 x Weekly  and 4 x Monthly backups. You can modify the backup policy by adding the config lines below to your existing config.pl
```perl
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
```


<br/>
## Help
```
/opt/plexWatch/plexWatch.pl --help
```
```
 PLEXWATCH(1)          User Contributed Perl Documentation         PLEXWATCH(1)

 NAME
        plexWatch.p - Notify and Log ’Now Playing’ and ’Watched’ content from a Plex Media Server + ’Recently Added

 SYNOPSIS
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

 OPTIONS
       --notify       This will send you a notification through prowl, pushover, boxcar, pushbullet, growl and/or twitter. It will also log the event to a file and to the database.  This is the default if no
                      options are given.

       --watched      Print a list of watched content from all users.

       --start        * only works with --watched

                      limit watched status output to content started AFTER said date/time

                      Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

                         -start=2013-06-29
                         -start="2013-06-29 8:00pm"
                         -start="today"
                         -start="today at 8:30pm"
                         -start="last week"
                         -start=... give it a try and see what you can use :)

       --stop         * only works with --watched

                      limit watched status output to content started BEFORE said date/time

                      Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

                         -stop=2013-06-29
                         -stop="2013-06-29 8:00pm"
                         -stop="today"
                         -stop="today at 8:30pm"
                         -stop="last week"
                         -stop=... give it a try and see what you can use :)

       --nogrouping   * only works with --watched

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

       ---user        * works with --watched and --watching

                      limit output to a specific user. Must be exact, case-insensitive

       --exclude_user limit output to a specific user. Must be exact, case-insensitive

       --watching     Print a list of content currently being watched

       --stats        show total watched time and show total watched time per day

       --recently_added
                      notify when new movies or shows are added to the plex media server (required: config.pl: push_recentlyadded => 1)

                       --recently_added=movie :: for movies
                       --recently_added=show  :: for tv show/episodes

       --show_xml     Print the XML result from query to the PMS server in regards to what is being watched. Could be useful for troubleshooting..

       --backup       By default this script will automatically backup the SQlite db to: $data_dir/db_backups/ ( normally: /opt/plexWatch/db_backups/ )

                      * you can force a Daily backup with --backup

                      It will keep 2 x Daily , 4 x Weekly  and 4 x Monthly backups. You can modify the backup policy by adding the config lines below to your existin config.pl

                      $backup_opts = {
                              ’daily’ => {
                                  ’enabled’ => 1,
                                  ’keep’ => 2,
                              },
                              ’monthly’ => {
                                  ’enabled’ => 1,
                                  ’keep’ => 4,
                              },
                              ’weekly’ => {
                                  ’enabled’ => 1,
                                  ’keep’ => 4,
                              },
                          };

       --debug        This can be used. I have not fully set everything for debugging.. so it’s not very useful

 DESCRIPTION
       This program will Notify and Log ’Now Playing’ content from a Plex Media Server

 HELP
       nothing to see here.

perl v5.10.1                      2013-08-13                      PLEXWATCH(1)
```



<br/>
## FAQ

* __How do I test notifications__
----

__Answer__

```
 Make sure you have enabled a provider in the config.pl

   ./plexWatch.pl --test_notify=start
   ./plexWatch.pl --test_notify=stop
   ./plexWatch.pl --test_notify=recent

```



* __I receive this error when running a test notification:__
----

```
Can't verify SSL peers without knowning which Certificate Authorities to trust

This problem can be fixed by either setting the PERL_LWP_SSL_CA_FILE
envirionment variable or by installing the Mozilla::CA module.
```

__Answer__

```
sudo cpan
install LWP::UserAgent Mozilla::CA
```

__OSX__
* remove homebrew and macports. Force reinstalled modules, highly recommend installing Mozilla::CA prior to LWP::UserAgent



* __How do I setup a launchagent in OSX__
----

__Answer__

Create a LaunchAgent plist file, called com.rcork.plexwatch.plist. This should be saved in ~/Library/LaunchAgents/

```
vim ~/Library/LaunchAgents/com.rcork.plexwatch.plist
```
Paste this text into the file, changing the /path/to/your/plexWatch variable, as appropriate. If you followed the directions above, this should be /opt/plexWatch/plexWatch.pl

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.rcork.plexwatch</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/perl</string>
		<string>/path/to/your/plexWatch/plexWatch.pl</string>
		<string>-notify</string>
		<string>-recently_added=movie,show</string>
	</array>
	<key>StartInterval</key>
	<integer>30</integer>
</dict>
</plist>
```

After you edit and save the file, you need to load the LaunchAgent:
```
launchctl load ~/Library/LaunchAgents/com.rcork.plexwatch.plist
```


* __How do I install on OSX__
----

__Answer__

 : User contribution - Thanks rcork!

 Here are the steps to get it running on OSX. This was done with a clean install of OSX.
 * refer to the INSTALL section above for more details. This is a brief rundown.

1. Download plexWatch from github and unzip
2. Copy config.pl-dist to config.pl and modify for your notification options
3. Install XCode from Mac App Strore
4. Install XCode command line tools by launching XCode, going to preferences, downloads, Install Command Line Tools
    1. If this does not work, from Terminal, type "xcode-select --install"
    2. Software Update should now prompt you to install the Developer Tools. Install them.
5. Configure CPAN
    1. Launch Terminal.app
    2. Type "cpan" without the quotes and press enter
    3. If this is first time launching cpan, it will ask if you want to automatically configure. Hit Enter
        1. It will ask if you want to automatically pick download mirrors. Type No and hit enter
        2. Pick mirrors for your region. I've had the best luck with .edu mirrors
    4. Type "install CPAN" without the quotes and hit enter. This will update cpan to the latest version
    5. Type "reload cpan" without the quotes and hit enter.
    6. Type "exit" without the quotes and hit enter
    7. Install required perl modules from Terminal

    ```
    sudo cpan install Time::Duration
    sudo cpan install Time::ParseDate
    sudo cpan install Net::Twitter::Lite::WithAPIv1_1
    sudo cpan install Net::OAuth
    sudo cpan install Mozilla::CA
    sudo cpan install JSON
    ```
7. Now create data directory and set permission. Replace [user] with your username

     ```
     sudo mkdir /opt
     sudo mkdir /opt/plexWatch
     sudo chown [user]:staff /opt/plexWatch
     ```
8. Run plexWatch from Terminal. You shouldn't receive any errors or warnings
    ```
    ./plexWatch.pl
    ```







----
Idea, thanks to https://github.com/vwieczorek/plexMon. I initially had a really horrible script used to parse the log files...  http://IP:PORT/status/sessions is much more useful. This was whipped up in an hour or two.. I am sure it could use some more work.
