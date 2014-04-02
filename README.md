# The WABAC Machine

The WABAC Machine is a simple but powerful **backup** utility inspired by Apple's TimeMachine(c).


## Overview

  * Incremental backups.

  * Stores each backup in its own folder named after the current timestamp.

  * Uses hard-links to save space.

  * Supports excluding files (and patterns).

  * Smart purge. The WABACMachine keeps :
    * everything for the last 24 hours,
    * daily backups for the past 30 days,
    * weekly backups for the last 52 weeks,
    * monthly backups for the last 24 monthes. 

  * Automatically deletes oldest backups when the destination volume runs out of space.

  * External config file.

  * *latest* symbolic points to the last successful backup.

  * Uses extended attributes to protect the backups.

  * Supports remote backups through SSH. (***PLANNED***)


## Setup

### Requirements

The WABAC Machine uses `rsync` to run. It also uses extended attributes (aka *xattrs*) to secure the backups.
Of course, you may need to run it as root to backup some files/directories.

### Configuring for local backups

If you plan to backup your files on a external hard disk drive, on a separate partition or in a specific folder, you are doing local backups.
It's very easy to setup.

Edit the `WABACMachine.conf` file provided to fit your needs :

    


### Automating the backup process

It's generally a good idea to automate your backup process, so you don't have to run it manually. If you are running systemd on your system, follow those steps to make the WABAC Machine run as a background service.

#### Setting up a systemd unit

Using systemd to schedule the job (instead of cron, for example) allows you to precisely allocate resources for the job to run properly (`IOSchedulingPriority`, `Nice`, ...). It also allows you to set dependencies between units, like mounting a volume before sending the backup to it.

First, create the *timer* unit, `/etc/systemd/system/timer-hourly.timer` :

    [Unit]
    Description=Hourly Timer
    
    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=1h
    Unit=timer-hourly.target
    
    [Install]
    WantedBy=basic.target

Then create the *target*, `/etc/systemd/system/timer-hourly.target` :

    [Unit]
    Description=Hourly Timer Target
    StopWhenUnneeded=yes

Finally, create the needed directory :

    # mkdir /etc/systemd/system/timer-hourly.target.wants

Enable the hourly timer you just created :
    
    # systemctl enable timer-hourly.timer

To make something run each hour, you just have to create a systemd service file for it and drop it into `/etc/systemd/system/timer-hourly.target.wants`.

So let's create `/etc/systemd/system/timer-hourly.target.wants/WABACMachine.service` :

    [Unit]
    Description=The WABAC Machine
    
    [Service]
    Type=simple
    Nice=19
    IOSchedulingPriority=7
    IOSchedulingClass=best-effort
    StandardOutput=journal
    StandardError=journal
    ExecStart=/path/to/WABACMachine.sh

At this point you might want to disable the hourly timer if you haven't setup your WABAC Machine properly. To do so, run :
    
    # systemctl disable timer-hourly.timer

Setup your WABAC Machine (see the next sections), test it, and re-enable `timer-hourly.timer` after.

**Important note** : those are examples that are known to work. You may want to specify others values, depending on your setup, needs and system.

#### Using cron

If you are not using systemd, or if you want to keep your scheduled tasks in cron, edit your crontab as root :

    # crontab -e

And add an entry for the WABAC Machine :

    @hourly /path/to/WABACMachine.sh

Save the file. You're done !


## Monitoring the WABAC Machine

### Using journalctl

If you are using systemd to run the WABAC Machine, you can use `journalctl` to monitor it. To do so, run

    journalctl -f -u WABACMachine

to see what's happening in real time.

Note that only root and users who are members of the *systemd-journal* group are able to read these logs.

### Using legacy tools

If you are not using systemd, or if you are outputing the WABAC Machine logs to a regular file, you can still use legacy tools to monitor the WABAC Machine. By default, if you run the WABAC Machine via cron, the output will be appended to `/var/log/syslog`. Running the following as root should allow you monitor the WABAC Machine.

    # tail -f /var/log/syslog

Anyway, since `/var/log/syslog` also contains others daemons log, it's not really convenient. It is a better idea to redirect the WABAC Machine output to a specific log file. You could modify your cron entry as follow :

    @hourly /path/to/WABACMachine.sh > /var/log/WABACMachine.log 2>&1

And then run :

    # tail -f /var/log/WABACMachine.log

to monitor the WABAC Machine.

## Resources

  * Use systemd as a cron replacement : http://blog.higgsboson.tk/2013/06/09/use-systemd-as-a-cron-replacement/
  * 