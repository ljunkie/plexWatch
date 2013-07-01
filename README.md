plexWatch
=========

***Notify*** and Log ***'Now Playing'*** content from a Plex Media Server

**Suported Push Notifications** 
* https://pushover.net (not fully tested - want to gift me the app for iOS/android?)
* https://prowlapp.com (tested)

**What it does**
* Checks if a video has been started or stopped - log and notify
* Notifies via prowl, pushover and/or a log file
* backed by a sqlite DB (for state and history)

###Perl Requirements

* LWP::UserAgent
* WWW::Curl::Easy
* XML::Simple
* DBI
* Time::Duration;
* Time::ParseDate;
* Pod::Usage;       (perl base on rhel/centos)
* Fcntl qw(:flock); (perl base)
* Getopt::Long;     (perl base)

### Install 

1) sudo wget -P /opt/plexWatch/ https://raw.github.com/ljunkie/plexWatch/master/plexWatch.pl

2) sudo chmod 755 /opt/plexWatch/plexWatch.pl

3) sudo nano /opt/plexWatch/plexWatch.pl 


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

* Prow: required you fill in 'apikey' 
* PushOver: required to fill in 'token' and 'user'
```

4) Install Perl requirements

* Debian/Ubuntu - apt-get

```
sudo apt-get install libwww-perl

sudo apt-get install libwww-curl-perl

sudo apt-get install libxml-simple-perl

sudo apt-get install libtime-duration-perl

sudo apt-get install libtime-modules-perl  

sudo apt-get install libdbd-sqlite3-perl

sudo apt-get install perl-doc
```

* RHEL/Centos - yum

```
yum -y install perl\(LWP::UserAgent\) perl\(WWW::Curl::Easy\) perl\(XML::Simple\) \
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

## Using the script


### Sending Notifications 

* Follow the install guide above, and refer to step #5 and #6


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

#### list watched shows, -nogrouping vs default

#####  with --nogroupoing
```

       Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 27 minutes and 54 seconds]
       Sun Jun 30 15:41:02 2013: exampleUser watched: Your Highness [2011] [R] [duration: 4 minutes and 59 seconds]
       Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 24 minutes and 17 seconds]
       Sun Jun 30 17:48:01 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 1 hour, 44 minutes, and 1 second]
       Sun Jun 30 19:45:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour and 24 minutes]

#####  without --nogrouping [default]
      Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour, 56 minutes, and 53 seconds]
      Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 2 hours, 8 minutes, and 18 seconds]
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

          -watching=...      print content being watched

          -show_xml=...      show xml result from api query
          -debug=...         hit and miss - not very useful

OPTIONS
       -notify        This will send you a notification through prowl and/or pushover. It will also log the event to a file and to the database.  
                      This is the default if no options are given.

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

                      with --nogroupoing
                       Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 27 minutes and 54 seconds]
                       Sun Jun 30 15:41:02 2013: exampleUser watched: Your Highness [2011] [R] [duration: 4 minutes and 59 seconds]
                       Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 24 minutes and 17 seconds]
                       Sun Jun 30 17:48:01 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 1 hour, 44 minutes, and 1 second]
                       Sun Jun 30 19:45:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour and 24 minutes]

                      without --nogrouping [default]
                       Sun Jun 30 15:12:01 2013: exampleUser watched: Your Highness [2011] [R] [duration: 1 hour, 56 minutes, and 53 seconds]
                       Sun Jun 30 15:46:02 2013: exampleUser watched: Star Trek [2009] [PG-13] [duration: 2 hours, 8 minutes, and 18 seconds]

       -watching      Print a list of content currently being watched

       -show_xml      Print the XML result from query to the PMS server in regards to what is being watched. Could be useful for troubleshooting..

       -debug         This can be used. I have not fully set everything for debugging.. so it’s not very useful

DESCRIPTION
       This program will Notify and Log ’Now Playing’ content from a Plex
       Media Server

HELP
       nothing to see here.



perl v5.10.1                      2013-06-28                      PLEXWATCH(1)
```


Idea, thanks to https://github.com/vwieczorek/plexMon. I initially had a really horrible script used to parse the log files...  http://IP:PORT/status/sessions is much more useful. This was whipped up in an hour or two.. I am sure it could use some more work. 
