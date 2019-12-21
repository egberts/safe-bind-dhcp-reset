#!/bin/bash
#
# bind-dhcp-reset.sh
#
# License: MIT, copyright Stephen Egbert
#
# A dual reset of a bastion host running two bind9 (public/internal) daemons
# and an internal DHCP server/daemon.
#
# Deals with quirk of dynamic zones within a view and its data integrity
# during named daemon failure (power-outage, process killed, errors).
#
# Debian 8/9/10 file system layout
# ISC Bind9 v9.15
# ISC DHCP v4.4.1

PUBLIC_DOMAIN_FQDN="example.com"
INTERNAL_DOMAIN_FQDN="local"
INTERNAL_VIEWED_DYNAMIC_ZONE="green"

# checkzone <zone-name> <class> <zone-db-file>
function checkzone()
{
  echo "Performing named-checkzone -c $2 $1 $3..."
  named-checkzone \
        -i full \
        -S warn \
        -c $2 \
        $1 $3
  RETSTS=$?
  if [ $RETSTS -ne 0 ]; then
    echo "ERROR: Zone: $1 File: $3: Errno: $RETSTS"
    exit $RETSTS
  fi
}


# must_have_include <named.conf-path>
function must_have_include()
{
  # echo "Checking that named.conf is broken into many files via include statements..."
  INCLUDE_STATEMENT_COUNT="`cat $1 | egrep -c '^[[:space:]]*include '`"
  if [ -z $INCLUDE_STATEMENT_COUNT ]; then
    echo "No include statement found in $1"
    exit -1
  fi
}


# add_any_include_files <filespec>
function add_any_include_files()
{
  # echo "Include statements: $INCLUDE_STATEMENT_COUNT"
  # Make a list of include statements to read
  INCLUDE_STATEMENTS="`cat $1 | egrep '^[[:space:]]*include ' | awk -F '"' '{print $2}'`"
  # echo "add_any_include_files: $INCLUDE_STATEMENTS"
}

# reduce_include_files <list>
function reduce_include_files
{
  RET_INCFILES=
  INCFILES=$1
  for THISINC in $INCFILES; do
    # echo "Checking if $THISINC has any zone/view statements..."
    # find any zone or view
    ZONES_FOUND="`cat $THISINC | egrep -c '^[[:space:]]*zone '`"
    ZONE_STATEMENT="`cat $THISINC | egrep '^[[:space:]]*zone '`"
    ZONENAME="`echo $ZONE_STATEMENT | awk -F ' ' '{print $2}' | sed -e 's/\"//g'`"
    if [ $ZONES_FOUND -gt 0 ]; then
      SLAVE_FOUND="`cat $THISINC | egrep -c '^[[:space:]]*type[[:space:]]*slave[[:space:]]*;'`"
      if [ $SLAVE_FOUND -eq 0 ]; then
        RET_INCFILES="$RET_INCFILES $THISINC"
        echo "zone $ZONENAME found in $THISINC"
      fi
    fi
  done
}


# checkconf <named.conf-path>
function checkconf()
{
  NAMED_CONF=$1
  echo "Checking $NAMED_CONF named configuration file..."
  if [ ! -r $NAMED_CONF ]; then
    echo "File $NAMED_CONF is not readable: aborting..."
    exit -1
  fi
  must_have_include $NAMED_CONF
  add_any_include_files $NAMED_CONF
  ALL_INCFILES="$INCLUDE_STATEMENTS"
  SEC_INCFILES=

  # Scan through 2nd-nested each include statement for "include"
  for THIS_INCFILE in $ALL_INCFILES; do
    # echo "Finally processing 2nd-nested $THIS_INCFILE..."
    INCFILES_FOUND="`cat $THIS_INCFILE | egrep -c '^[[:space:]]*include '`"
    if [ $INCFILES_FOUND -gt 0 ]; then
      # echo "Include(s) found in $THIS_INCFILE"
      add_any_include_files $THIS_INCFILE
      ALL_INCFILES="$ALL_INCFILES $INCLUDE_STATEMENTS"
      SEC_INCFILES="$SEC_INCFILES $INCLUDE_STATEMENTS"
    fi
  done

  # Scan through 3rd-nested each include statement for "include"
  for THIS_INCFILE in $SEC_INCFILES; do
    # echo "Finally processing 3rd-nested $THIS_INCFILE..."
    INCFILES_FOUND="`cat $THIS_INCFILE | egrep -c '^[[:space:]]*include '`"
    if [ $INCFILES_FOUND -gt 0 ]; then
      # echo "Include(s) found in $THIS_INCFILE"
      add_any_include_files $THIS_INCFILE
      ALL_INCFILES="$ALL_INCFILES $INCLUDE_STATEMENTS"
    fi
  done
  # echo "All include files: $ALL_INCFILES"

  reduce_include_files "$ALL_INCFILES"
  ALL_ZONE_CONFS="$RET_INCFILES"
  # echo "Remaining include files having zone: $ALL_ZONE_CONFS"

  # We take list of named.conf files (or its include-derivative)
  # this assumes "file" statement is in same file as "zone" statement
  for THIS_ZONE_CONF in $ALL_ZONE_CONFS; do

    # and look for "zone" statement to submit to named-checkzone
    # extract zone name and if any its class as well
    ZONE_STATEMENT="`cat $THIS_ZONE_CONF | egrep '^[[:space:]]*zone '`"
    ZONENAME="`echo $ZONE_STATEMENT | awk -F ' ' '{print $2}' | sed -e 's/\"//g'`"
    if [ "$ZONENAME" == "." ]; then
      continue
    fi
    CLASSNAME="`echo $ZONE_STATEMENT | awk -F ' ' '{print $3}' | sed -e 's/://'`"
    if [ "$CLASSNAME" == "{" ]; then
      CLASSNAME="IN"
    fi
    if [ -z $CLASSNAME ]; then
      CLASSNAME="IN"
    fi

    # and look for "file" statement to submit to named-checkzone
    FILE_FOUND="`cat $THIS_ZONE_CONF | egrep -c '^[[:space:]]*file '`"
    if [ $FILE_FOUND -eq 0 ]; then
      echo "No file statement found for Zone $ZONENAME "
      echo "    in file $THIS_ZONE_CONF"
      exit 1
    fi
    FILESPEC="`cat $THIS_ZONE_CONF | egrep '^[[:space:]]*file ' | awk -F '"' '{ print $2}'`"
    checkzone $ZONENAME $CLASSNAME $FILESPEC
  done
  # returns VIEWS_LIST
  named-checkconf -zj $NAMED_CONF
  RETSTS=$?
  if [ $RETSTS -ne 0 ]; then
    echo "named-checkconf $NAMED_CONF FAILED! Aborted."
    exit 5
  fi
}

# Check DHCPD conf
echo "Checking ISC dhcpd server configuration settings ..."
dhcpd -d -q -f -t
RETSTS=$?
if [ $RETSTS -ne 0 ]; then
  echo "DHCP configuration failed sanity check"
  exit $RETSTS
fi
echo "Checking ISC dhcpd server lease file ..."
dhcpd -d -q -f -t -T
RETSTS=$?
if [ $RETSTS -ne 0 ]; then
  echo "DHCP lease failed sanity check"
  exit $RETSTS
fi

rndc -p 953 -c /etc/bind/rndc.conf reload
RETSTS=$?
if [ $RETSTS -ne 0 -a $RETSTS -ne 1 ]; then
  echo "rndc failed to reload Internal DNS server"
  exit $RETSTS
fi
rndc -p 954 -c /etc/bind/rndc-public.conf reload
RETSTS=$?
if [ $RETSTS -ne 0 -a $RETSTS -ne 1 ]; then
  echo "rndc failed to reload Public DNS server"
  exit $RETSTS
fi

# Still a custom job to determine which zone (and view) to
#  unfreeze for Dynamic DNS

# Dynamic DNS is only used within Bind-Internal
# Unfreeze Bind-Internal
rndc -p 954 -c /etc/bind/rndc-public.conf sync -clean
rndc -p 954 -c /etc/bind/rndc-public.conf sign "$PUBLIC_DOMAIN_FQDN" red
rndc -p 954 -c /etc/bind/rndc-public.conf sign "$PUBLIC_DOMAIN_FQDN"
rndc -p 954 -c /etc/bind/rndc-public.conf notify "$PUBLIC_DOMAIN_FQDN"
rndc freeze "$INTERNAL_DOMAIN_FQDN" IN "$INTERNAL_VIEWED_DYNAMIC_ZONE"
rm /var/lib/bind/*.jnl
rm /var/cache/bind/*.jnl
rndc thaw "$INTERNAL_DOMAIN_FQDN" IN "$INTERNAL_VIEWED_DYNAMIC_ZONE"




# Close DHCP server, Bind-Internal, then Bind-External
echo "Stopping all DHCP client and DNS servers..."
systemctl stop dhclient@eth1.service
systemctl stop bind9-internal.service
systemctl stop bind9-public.service


# Clean up any files
rm -rf /var/lib/bind/internal/slave/*.slave


# Start DHCP server, Bind-Internal, then Bind-External
echo "Starting DHCP client"
systemctl start dhclient@eth1.service
RETSTS=$?
if [ $RETSTS -ne 0 ]; then
  echo "Error in DHCP client; fix that firstly..."
  exit $RETSTS
fi

# check the DHCP files using 'named-checkconf'
# Check namedconf
NAMED_CONF="/etc/bind/named-public.conf"
checkconf $NAMED_CONF

NAMED_CONF="/etc/bind/named-internal.conf"
checkconf $NAMED_CONF


# these series of 'rm' is needed until BIND 9.12+
rm /var/cache/bind/*.jbk
rm /var/cache/bind/internal/*.jbk
rm /var/cache/bind/public/*.jbk
rm /var/lib/bind/*.jnl
rm /var/lib/bind/*.signed
rm /var/lib/bind/internal/*.jnl
rm /var/lib/bind/internal/*.signed
rm /var/lib/bind/internal/master/*.jnl
rm /var/lib/bind/internal/master/*.signed
rm /var/lib/bind/internal/slave/*.jnl
rm /var/lib/bind/internal/slave/*.signed
rm /var/lib/bind/internal/dynamic/*.jnl
rm /var/lib/bind/internal/dynamic/*.signed
rm /var/lib/bind/public/*.jnl
rm /var/lib/bind/public/*.signed
rm /var/lib/bind/public/master/*.jnl
rm /var/lib/bind/public/master/*.signed
rm /var/lib/bind/public/slave/*.jnl
rm /var/lib/bind/public/slave/*.signed
rm /var/lib/bind/public/dynamic/*.jnl
rm /var/lib/bind/public/dynamic/*.signed

systemctl start bind9-internal.service
RETSTS=$?
if [ $RETSTS -ne 0 ]; then
  echo "Error in starting bind9-internal.service; fix that firstly..."
  exit $RETSTS
fi


systemctl start bind9-public.service
RETSTS=$?
if [ $RETSTS -ne 0 ]; then
  echo "Error in starting bind9-public.service; fix that firstly..."
  exit $RETSTS
fi

# Check status of DHCP server, Bind-Internal, then Bind-External
systemctl status -l --lines=20 --no-pager isc-dhcp-server.service
systemctl status -l --lines=20 --no-pager bind9-internal.service
systemctl status -l --lines=20 --no-pager bind9-public.service

rndc -p 954 -c /etc/bind/rndc-public.conf zonestatus egbert.net

# This echo command below erases the RETSTS/$? from previous commands
echo "End of $0"

