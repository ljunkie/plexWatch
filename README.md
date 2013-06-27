plexWatch
=========

***Notify*** and Log ***'Now Playing'*** content from a Plex Media Server

**Suported Push Notifications** 
* https://pushover.net (tested)
* https://prowlapp.com (not fully tested - want to gift me the app for iOS/android?)

**What it does**
* Checks if a video has been started or stopped - log and notify
* Notifies via prowl, pushover and/or a log file
* backed by a sqlite DB (for state and history)

###Perl Requirements

* LWP::UserAgent
* WWW::Curl::Easy
* XML::Simple
* DBI

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
