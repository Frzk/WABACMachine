# The WABAC Machine

The WABAC Machine is an open-source, simple yet powerful **backup** utility written for UNIX-like systems. It uses **rsync** to perform efficient backups with a smart retention strategy. It has been tested on GNU/Linux (ext3 and Btrfs filesystems) and OSX (HFS+ filesystem).

For Solaris, BSD and others Unices, a few things are currently missing.

## Features

  * Incremental backups.

  * Stores each backup in its own folder named after the current timestamp.

  * Uses hard-links to save space.

  * Supports excluding files (and patterns).

  * Smart backup retention. The WABACMachine keeps (defaults config) :
    * everything for the last 24 hours,
    * daily backups for the past 30 days,
    * weekly backups for the last 52 weeks,
    * monthly backups for the last 24 monthes. 

  * Automatically deletes oldest backups when the destination volume runs out of space.

  * Resumes failed/interrupted file transfers.

  * Resumes failed/interrupted backups.

  * External config file.

  * *latest* symbolic points to the last successful backup.

  * Supports remote backups.

  * Supports preflight and postflight scripts.

## Documentation

We provide a [wiki](https://github.com/Frzk/WABACMachine/wiki/) that will hopefully help you.