# The WABAC Machine

The WABAC Machine is a simple **backup** utility inspired by Apple's TimeMachine(c).

## Overview

Each time it runs, The WABAC Machine creates a snapshot of your files. This snapshot is named after the current date and time so ou can easily retrieve and restore an old file.


## How it works

The WABAC Machine creates a folder on the destination volume that's named after the current date and time. It then copies all files designated as source (except files and directories that have specifically been told not to copy) to the folder.
Each time it runs, the WABAC Machine creates a new folder using the same naming convention. But instead of copying all files, the WABAC Machine only copies files that have changed since the last backup and creates hard-links for the other ones. Each backup folder contains all your files (except ones that have specifically been excluded). The use of hard-links saves space and makes backups easily "browsable".

The default configuration of the WABAC Machine will keep :
  * everything for the past 24 hours,
  * daily backups for the past 30 days,
  * weekly backups for the last 52 weeks,
  * monthly backups for the last 24 monthes.

When the destination volume runs out of space, the WABAC Machine deletes the oldest snapshot until it gets enough space to c reate a new snapshot.


## Setup

Edit the WABACMachine.conf file to suit your needs.
Setup a cron job or create a systemd unit.


## Requirements

The WABAC Machine uses rsync to run.
Of course, you may need to run it as root to backup some files/directories.