plexWatch - 0.0.17-4-dev
=========

***Notify*** and Log ***'Now Playing'*** and ***'Watched'*** content from a Plex Media Server + ***'Recently Added'*** (...and more)

**Supported Push Notifications** 
* https://pushover.net
* https://prowlapp.com
* http://growl.info/ (via GrowlNotify @ http://growl.info/downloads#generaldownloads)
* https://twitter.com/ (create a new app @ https://dev.twitter.com/apps)
* https://boxcar.io/ 
* SNARL/GROWL: GNTP notifications supported. Anything that uses GNTP *should* work

**What it does**
* notify when a user starts watching a video
* notify when a user stop watching a video
* notify on recently added content to a PMS server
* notifies via prowl, pushover, growl, twitter, boxcar and/or a log file
* notifications per provider enabled/disabled per notification type (watching, watched, recently added)
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

#### These should be part of the bast Perl install

* Pod::Usage;        (Perl base on rhel/centos)
* Fcntl qw(:flock);  (Perl base)
* Getopt::Long;      (Perl base)
* POSIX qw(strftime) (Perl base)
* File::Basename     (Perl base)

#### Required ONLY if you use twitter

* Net::Twitter::Lite::WithAPIv1_1
* Net::OAuth

#### Required ONLY if you use GNTP

* Growl::GNTP

### Install 

1) sudo wget -P /opt/plexWatch/ https://raw.github.com/ljunkie/plexWatch/master/plexWatch.pl

2) sudo chmod 755 /opt/plexWatch/plexWatch.pl

3) sudo cp /opt/plexWatch/config.pl-dist /opt/plexWatch/config.pl 

3a) sudo nano /opt/plexWatch/config.pl 

Modify Variables as needed:
```
$server = 'localhost';   ## IP of PMS - or localhost
$port   = 32400;         ## port of PMS
$notify_started = 1;   ## notify when a stream is started (first play)
$notify_stopped = 1;   ## notify when a stream is stopped 

```

```
$notify = {...

* to enable a provider, i.e. file, prowl, pushover 
   set 'enabled' => 1, under selected provider

* Prowl     : 'apikey' required
* Pushover  : 'token' and 'user' required
* Growl     : 'script' required :: GrowlNotify from http://growl.info/downloads
* twitter   : 'consumer_key', 'consumer_secret', 'access_token', 'access_token_secret' required
* boxcar    : 'email' required
```

4) Install Perl requirements

* Debian/Ubuntu - apt-get

```
sudo apt-get install libwww-perl

sudo apt-get install libxml-simple-perl

sudo apt-get install libtime-duration-perl

sudo apt-get install libtime-modules-perl  

sudo apt-get install libdbd-sqlite3-perl

sudo apt-get install perl-doc
```

* RHEL/Centos - yum

```
yum -y install perl\(LWP::UserAgent\) perl\(XML::Simple\) \
               perl\(DBI\) perl\(Time::Duration\)  perl\(Time::ParseDate\)
```


5) **run** the script manually to verify it works: /opt/plexWatch/plexWatch.pl
  * start video(s)
  * /opt/plexWatch/plexWatch.pl
  * stop video(s)
  * /opt/plexWatch/plexWatch.pl


6) setup cron - /etc/crontab
```
* * * * * root cd /opt/plexWatch && /opt/plexWatch/plexWatch.pl
```

### Twitter integration 
If you want to use twitter, you will need to install two more Perl modules

*  requires Net::Twitter::Lite::WithAPIv1_1  
```
cpan Net::Twitter::Lite::WithAPIv1_1
```

*  requires Net::OAuth >= 0.28
```
cpan Net::OAuth
```


#### Twitter setup
* create a new app @ https://dev.twitter.com/apps
* make sure to set set ApplicationType to read/write
* enable notification for twitter in config.pl



### GNTP integration
If you want to use GNTP (growl), you will need to install a module

*  requires Growl::GNTP
```
cpan Growl::GNTP
```

* Note: CPAN install failed on centos until I installed perl\(Data::UUID\)



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
/opt/git/plexWatch/plexWatch.pl --watched 

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
/opt/git/plexWatch/plexWatch.pl --watched --start=today --start=tomorrow

======================================== Watched ========================================
Date Range: Fri Jun 28 00:00:00 2013 through Sat Jun 29 00:00:00 2013

User: jimbo
 Fri Jun 28 09:18:22 2013: jimbo watched: Married ... with Children - Mr. Empty Pants [duration: 1 hour, 23 minutes, and 20 seconds]
```

##### list watched shows - limit by a start and stop date
```
/opt/git/plexWatch/plexWatch.pl --watched --start="2 days ago" --stop="1 day ago"

======================================== Watched ========================================
Date Range: Fri Jun 26 00:00:00 2013 through Thu Jun 27 00:00:00 2013

User: Jimbo
 Wed Jun 26 15:56:09 2013: rarflix watched: South Park - A Nightmare on FaceTime [duration: 22 minutes, and 15 seconds]
 Wed Jun 26 20:18:34 2013: rarflix watched: The Following - Whips and Regret [duration: 46 minutes, and 45 seconds]
 Wed Jun 26 20:55:02 2013: rarflix watched: The Following - The Curse [duration: 46 minutes, and 15 seconds]

User: Carrie
 Wed Jun 26 20:19:48 2013: Carrie watched: Dumb and Dumber [1994] [PG-13] [duration: 1 hour, 7 minutes, and 10 seconds]
```

#### list watched shows: option -nogrouping vs default

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
/opt/git/plexWatch/plexWatch.pl --stats

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

####config.pl options
```
$alert_format = {
	         'start'    =>  '{user} watching {title} on {platform}',
		 'stop'     =>  '{user} watched {title} on {platform} for {duration}',
		 'watched'  =>  '{user} watched {title} on {platform} for {duration}',
		 'watching' =>  '{user} watching {title} on {platform}'
                 };
```

####Format options Help
```
/opt/plexWatch/plexWatch.pl --format_options

Format Options for alerts

            --start='{user} watching {title} [{year}] [{rating}] on {platform}'
             --stop='{user} watched {title} [{year}] [{rating}] on {platform} for {duration}'
          --watched='{user} watched {title} [{year}] [{rating}] on {platform} for {duration}'
         --watching='{user} watching {title} [{year}] [{rating}] [{length}] on {platform} [{time_left} left]'

    {orig_user} orig_user
     {progress} progress of video [only available on --watching]
     {duration} duration watched
       {rating} rating of video - TV-MA, R, PG-13, etc
       {length} length of video
      {summary} summary or video
         {user} user
    {stop_time} stop_time
    {time_left} progress of video [only available on --watching]
        {title} title
     {platform} client platform 
  {start_start} start_time
         {year} year of video
```

### Help
```
/opt/plexWatch/plexWatch.pl --help
```
```
PLEXWATCH(1)          User Contributed Perl Documentation         PLEXWATCH(1)

NAME
       plexWatch.pl - Notify and Log ’Now Playing’ content from a Plex Media Server

SYNOPSIS
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

          --format_stop=".."      : modify stop notification :: --format_stop='{user} watched {title} on {platform} for {duration}'

          --format_watched=".."   : modify cli output for --watched  :: --format_watched='{user} watched {title} on {platform} for {duration}'

          --format_watching=".."  : modify cli output for --watching :: --format_watching='{user} watching {title} on {platform}'

          ############################################################################################3

          * Debug Options

          -test_notify=start        send a test notification for a start event. To test a stop event use -test_notify=stop
          -show_xml                 show xml result from api query
          -debug                    hit and miss - not very useful

OPTIONS
       -notify        This will send you a notification through prowl and/or pushover. It will also log the event to a file and to the database.  This is the default if no options are given.

       -watched       Print a list of watched content from all users.

       -start         * only works with -watched

                      limit watched status output to content started AFTER said date/time

                      Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

                         -start=2013-06-29
                         -start="2013-06-29 8:00pm"
                         -start="today"
                         -start="today at 8:30pm"
                         -start="last week"
                         -start=... give it a try and see what you can use :)

       -stop          * only works with -watched

                      limit watched status output to content started BEFORE said date/time

                      Valid options: dates, times and even fuzzy human times. Make sure you quote an values with spaces.

                         -stop=2013-06-29
                         -stop="2013-06-29 8:00pm"
                         -stop="today"
                         -stop="today at 8:30pm"
                         -stop="last week"
                         -stop=... give it a try and see what you can use :)

       -nogrouping    * only works with -watched

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

       -user          * works with -watched and -watching

                      limit output to a specific user. Must be exact, case-insensitive

       -watching      Print a list of content currently being watched

       -stats         show total watched time and show total watched time per day

       -show_xml      Print the XML result from query to the PMS server in regards to what is being watched. Could be useful for troubleshooting..

       -debug         This can be used. I have not fully set everything for debugging.. so it’s not very useful

DESCRIPTION
       This program will Notify and Log ’Now Playing’ content from a Plex Media Server

HELP
       nothing to see here.

perl v5.10.1                      2013-07-16                      PLEXWATCH(1)
```


Idea, thanks to https://github.com/vwieczorek/plexMon. I initially had a really horrible script used to parse the log files...  http://IP:PORT/status/sessions is much more useful. This was whipped up in an hour or two.. I am sure it could use some more work. 
