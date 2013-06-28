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
* Getopt::Long;
* Pod::Usage;
* Fcntl qw(:flock);
* Time::ParseDate;

### Install 

1) save to **/opt/prowlWatch/prowlWatch.pl**

2) chmod 755 /opt/prowlWatch/prowlWatch.pl

3) **edit** /opt/prowlWatch/prowlWatch.pl


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

4) **run** the script manually to verify it work 
  * start video(s)
  * run the script
  * stop video(s)
  * run the script


5) setup cron - /etc/crontab
```
* * * * * root cd /opt/plexWatch && /opt/plexWatch/plexWatch.pl
```


Idea, thanks to https://github.com/vwieczorek/plexMon. I initially had a really horrible script used to parse the log files...  http://IP:PORT/status/sessions is much more useful. This was whipped up in an hour or two.. I am sure it could use some more work. 


### Help
```
/opt/plexWatch/plexWatch.pl --help
```
```
PLEXWATCH(1)          User Contributed Perl Documentation         PLEXWATCH(1)


NAME
       plexWatch.pl - Notify and Log ’Now Playing’ content from a Plex Media
       Server

SYNOPSIS
       plexWatch.pl [options]

         Options:
          -notify=...        Notify any content watched and or stopped [this is default with NO options given]

          -watched=...       print watched content
          -start=...         limit watched status output to content started AFTER/ON said date/time
          -stop=...          limit watched status output to content started BEFORE/ON said date/time

          -watching=...      print content being watched

          -show_xml=...      show xml result from api query
          -debug=...         hit and miss - not very useful

OPTIONS
       -notify        This will send you a notification through prowl and/or
                      pushover. It will also log the event to a file and to
                      the database.  This is the default if no options are
                      given.

       -watched       Print a list of watched content from all users.

       -start         limit watched status output to content started AFTER
                      said date/time

                      Valid options: dates, times and even fuzzy human times.
                      Make sure you quote an values with spaces.

                         -start=2013-06-29
                         -start="2013-06-29 8:00pm"
                         -start="today"
                         -start="today at 8:30pm"
                         -start="last week"
                         -start=... give it a try and see what you can use :)

       -stop          limit watched status output to content started BEFORE
                      said date/time

                      Valid options: dates, times and even fuzzy human times.
                      Make sure you quote an values with spaces.

                         -stop=2013-06-29
                         -stop="2013-06-29 8:00pm"
                         -stop="today"
                         -stop="today at 8:30pm"
                         -stop="last week"
                         -stop=... give it a try and see what you can use :)

       -watching      Print a list of content currently being watched

       -show_xml      Print the XML result from query to the PMS server in
                      regards to what is being watched. Could be useful for
                      troubleshooting..

       -debug         This can be used. I have not fully set everything for
                      debugging.. so it’s not very useful

DESCRIPTION
       This program will Notify and Log ’Now Playing’ content from a Plex
       Media Server

HELP
       nothing to see here.



perl v5.10.1                      2013-06-28                      PLEXWATCH(1)
```


