#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
#
# Copyright 2009 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#

# ------------------------------------------------------------------
# OLTP Version 3.0
#
# iCAT / NVMeVirt 7.3 GiB SSD sizing
#
# Original workload behavior is preserved.
# Only the database data-set size is enlarged for the target SSD.
#
# datafiles:
#   10 files * 384 MiB = 3.75 GiB
#
# logfile:
#   1 file * 10 MiB = 10 MiB
#
# Total initial preallocated data:
#   ~3.76 GiB
#
# Target filesystem occupancy:
#   roughly 50~55%
# ------------------------------------------------------------------

set $dir=/tmp

set $eventrate=0
set $runtime=60

# OLTP random DB I/O size
set $iosize=2k

# Number of simulated database client/shadow processes
set $nshadows=200

# Number of database writer processes
set $ndbwriters=10

# CPU work per shadow process
set $usermode=200000

# ------------------------------------------------------------------
# DATASET SIZE
# ------------------------------------------------------------------

set $filesize=512m
set $nfiles=10

# Per-thread memory
set $memperthread=1m

# 0 = whole fileset can be selected as working set
set $workingset=0

# Log file configuration
set $logfilesize=10m
set $nlogfiles=1

# Preserve original Filebench OLTP behavior.
# aiowrite also uses dsync below.
set $directio=0


eventgen rate = $eventrate


# ------------------------------------------------------------------
# Database data files
#
# 10 * 384 MiB = 3.75 GiB
# prealloc=100:
# files are fully populated before measured workload execution.
# ------------------------------------------------------------------

define fileset name=datafiles,path=$dir,size=$filesize,entries=$nfiles,dirwidth=1024,prealloc=100,reuse


# ------------------------------------------------------------------
# Database log file
#
# 1 * 10 MiB
# ------------------------------------------------------------------

define fileset name=logfile,path=$dir,size=$logfilesize,entries=$nlogfiles,dirwidth=1024,prealloc=100,reuse


# ------------------------------------------------------------------
# Log writer
#
# Random 256 KiB asynchronous writes to the log file.
# dsync requests durable completion.
# ------------------------------------------------------------------

define process name=lgwr,instances=1
{
  thread name=lgwr,memsize=$memperthread,useism
  {
    flowop aiowrite name=lg-write,filesetname=logfile,
        iosize=256k,random,directio=$directio,dsync

    flowop aiowait name=lg-aiowait

    flowop semblock name=lg-block,value=3200,highwater=1000
  }
}


# ------------------------------------------------------------------
# Database writers
#
# 10 writer processes.
# Each writer issues 100 random 2 KiB writes per activation.
#
# Important for GC experiment:
# these are overwrites to existing database files, rather than
# delete/create cycles. Therefore old FTL mappings naturally become
# invalid when the same logical addresses are rewritten.
# ------------------------------------------------------------------

define process name=dbwr,instances=$ndbwriters
{
  thread name=dbwr,memsize=$memperthread,useism
  {
    flowop aiowrite name=dbwrite-a,filesetname=datafiles,
        iosize=$iosize,workingset=$workingset,random,iters=100,opennext,directio=$directio,dsync

    flowop hog name=dbwr-hog,value=10000

    flowop semblock name=dbwr-block,value=1000,highwater=2000

    flowop aiowait name=dbwr-aiowait
  }
}


# ------------------------------------------------------------------
# Shadow / user processes
#
# 200 processes perform random reads and generate work for
# the log writer and DB writers through semaphores.
# ------------------------------------------------------------------

define process name=shadow,instances=$nshadows
{
  thread name=shadow,memsize=$memperthread,useism
  {
    flowop read name=shadowread,filesetname=datafiles,
      iosize=$iosize,workingset=$workingset,random,opennext,directio=$directio

    flowop hog name=shadowhog,value=$usermode

    flowop sempost name=shadow-post-lg,value=1,target=lg-block,blocking

    flowop sempost name=shadow-post-dbwr,value=1,target=dbwr-block,blocking

    flowop eventlimit name=random-rate
  }
}


echo "OLTP Version 3.0 personality successfully loaded"

run 300