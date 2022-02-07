#!/bin/bash
#
# bind-reset.sh
#
# License: MIT, copyright Stephen Egbert
#
# A reset of a host running bind9 daemon
#
# Deals with quirk of dynamic zones within a view and its data integrity
# during named daemon failure (power-outage, process killed, errors).
#
# Debian 8/9/10 file system layout
# ISC Bind9 v9.15

echo "Resetting ISC Bind server (no DHCP option)"
echo

PUBLIC_DOMAIN_FQDN="egbert.net"
PUBLIC_BIND_DIR="/etc/bind"
PUBLIC_NAMED_CONF="/etc/bind/named.conf"
PUBLIC_RNDC_CONF="/etc/bind/rndc.conf"
PUBLIC_RNDC_OPT="-p 953"

# Get all the zones


# check_zone <zone-name> <class> <zone-db-file>
function check_zone()
{
  echo "Performing named-checkzone -c $2 $1 $3..."
  # named-checkzone -s relative -D -k fail   -m fail  -M fail -n fail -r fail -S fail -T warn -W fail -L 8399999 egbert.net /var/lib/bind/public/master/db.egbert.net

  named-checkzone \
        -f raw \
	-c $2 \
        -i full \
        -k fail \
        -m fail \
        -M fail \
        -n fail \
        -r fail \
        -S fail \
        -T warn \
        -W fail \
        $1 $3
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 ]]; then
    echo "ERROR: Zone: $1 File: $3: Errno: $RET_STS"
    exit ${RET_STS}
  fi
}


# must_have_include <named.conf-path>
function must_have_include()
{
  # echo "Checking that named.conf is broken into many files via include statements..."
  INCLUDE_STATEMENT_COUNT="`cat $1 | egrep -c '^[[:space:]]*include '`"
  if [[ -z ${INCLUDE_STATEMENT_COUNT} ]]; then
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

# reduce_include_files_to_having_slave_zones <list>
function reduce_include_files_to_having_slave_zones
{
  NONSLAVE_ZONES=
  RET_INC_FILES=
  INC_FILES=$1
  for THIS_INC in ${INC_FILES}; do
    # echo "Working on: $THIS_INC"
    # echo "Checking if $THISINC has any zone/view statements..."
    # find any zone or view
    ZONES_FOUND="`cat ${THIS_INC} | egrep -c '^[[:space:]]*zone '`"
    # echo "ZONES_FOUND: $ZONES_FOUND"
    ZONE_STATEMENT="`cat ${THIS_INC} | egrep '^[[:space:]]*zone '`"
    # echo "ZONE_STATEMENT: $ZONE_STATEMENT"
    ZONENAME="`echo ${ZONE_STATEMENT} | awk -F ' ' '{print $2}' | sed -e 's/\"//g'`"
    # echo "ZONENAME: $ZONENAME"
    if [[ ${ZONES_FOUND} -gt 0 ]]; then
      # Really should be an inverse pattern to 'master', not plain 'slave'
      # But 'rndc' does not want 'slave', 'mirror', or 'stub'
      SLAVE_FOUND="`cat ${THIS_INC} | egrep -c '^[[:space:]]*type[[:space:]]*(slave|mirror|stub)[[:space:]]*;'`"
      if [[ ${SLAVE_FOUND} -eq 1 ]]; then
        echo "  FOUND: Zone '$ZONENAME' is a slave"
        RET_INC_FILES="$RET_INC_FILES $THIS_INC"
        SLAVE_ZONENAMES="$ZONENAME $SLAVE_ZONENAMES"
      else
        echo "  IGNORED: Zone $ZONENAME is not a 'slave/mirror/stub' type."
      fi
    fi
  done
}


# check_conf <named.conf-path>
function check_conf()
{
  NAMED_CONF=$1
  echo "Checking $NAMED_CONF named configuration file..."
  if [[ ! -r ${NAMED_CONF} ]]; then
    echo "File $NAMED_CONF is not readable: aborting..."
    exit -1
  fi
  must_have_include "$NAMED_CONF"
  add_any_include_files "$NAMED_CONF"
  ALL_INC_FILES="$INCLUDE_STATEMENTS"
  SEC_INC_FILES=

  # Scan through 2nd-nested each include statement for "include"
  for THIS_INC_FILE in ${ALL_INC_FILES}; do
    # echo "Finally processing 2nd-nested $THIS_INCFILE..."
    INC_FILES_FOUND="`cat ${THIS_INC_FILE} | egrep -c '^[[:space:]]*include '`"
    if [[ ${INC_FILES_FOUND} -gt 0 ]]; then
      # echo "Include(s) found in $THIS_INCFILE"
      add_any_include_files "$THIS_INC_FILE"
      ALL_INC_FILES="$ALL_INC_FILES $INCLUDE_STATEMENTS"
      SEC_INC_FILES="$SEC_INC_FILES $INCLUDE_STATEMENTS"
    fi
  done

  # Scan through 3rd-nested each include statement for "include"
  for THIS_INC_FILE in ${SEC_INC_FILES}; do
    # echo "Finally processing 3rd-nested $THIS_INC_FILE..."
    INC_FILES_FOUND="`cat ${THIS_INC_FILE} | egrep -c '^[[:space:]]*include '`"
    if [[ ${INC_FILES_FOUND} -gt 0 ]]; then
      # echo "Include(s) found in $THIS_INCFILE"
      add_any_include_files "$THIS_INC_FILE"
      ALL_INC_FILES="$ALL_INC_FILES $INCLUDE_STATEMENTS"
    fi
  done
  # echo "All include files: $ALL_INCFILES"

  reduce_include_files_to_having_slave_zones "$ALL_INC_FILES"
  ALL_ZONE_CONFS="$RET_INC_FILES"
  # echo "Remaining include files having zone: $ALL_ZONE_CONFS"

  # We take list of named.conf files (or its include-derivative)
  # this assumes "file" statement is in same file as "zone" statement
  for THIS_ZONE_CONF in ${ALL_ZONE_CONFS}; do

    # and look for "zone" statement to submit to named-checkzone
    # extract zone name and if any its class as well
    ZONE_STATEMENT="`cat ${THIS_ZONE_CONF} | egrep '^[[:space:]]*zone '`"
    ZONENAME="`echo ${ZONE_STATEMENT} | awk -F ' ' '{print $2}' | sed -e 's/\"//g'`"
    if [[ "$ZONENAME" == "." ]]; then
      continue
    fi
    CLASS_NAME="`echo ${ZONE_STATEMENT} | awk -F ' ' '{print $3}' | sed -e 's/://'`"
    if [[ "$CLASS_NAME" == "{" ]]; then
      CLASS_NAME="IN"
    fi
    if [[ -z ${CLASS_NAME} ]]; then
      CLASS_NAME="IN"
    fi

    # and look for "file" statement to submit to named-checkzone
    FILE_FOUND="`cat ${THIS_ZONE_CONF} | egrep -c '^[[:space:]]*file '`"
    if [[ ${FILE_FOUND} -eq 0 ]]; then
      echo "No file statement found for Zone $ZONENAME "
      echo "    in file $THIS_ZONE_CONF"
      exit 1
    fi
    FILESPEC="`cat ${THIS_ZONE_CONF} | egrep '^[[:space:]]*file ' | awk -F '"' '{ print $2}'`"
    check_zone ${ZONENAME} ${CLASS_NAME} "$FILESPEC"
  done
  # returns VIEWS_LIST
  named-checkconf -zj "$NAMED_CONF"
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 ]]; then
    echo "named-checkconf $NAMED_CONF FAILED! Aborted."
    exit 5
  fi
}

# Check named.conf syntax before doing anything harmful
check_conf "$PUBLIC_NAMED_CONF"

echo "ALL_ZONES_CONF: $ALL_ZONE_CONFS"
for this_zone in $SLAVE_ZONENAMES; do
  echo "rndc: refreshing '${this_zone}' zone ..."
  rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" refresh ${this_zone}
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 && ${RET_STS} -ne 1 ]]; then
    echo "rndc failed to refresh zone '${ZONENAME}' server"
    exit ${RET_STS}
  fi
done

rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" reload
RET_STS=$?
if [[ ${RET_STS} -ne 0 && ${RET_STS} -ne 1 ]]; then
  echo "rndc failed to reload DNS server"
  exit ${RET_STS}
fi


# Still a custom job to determine which zone (and view) to
#  unfreeze for Dynamic DNS

# Dynamic DNS is only used within Bind-Internal
# Unfreeze Bind-Internal
echo "Cleaning '$PUBLIC_DOMAIN_FQDN' zone ..."
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" sync -clean
ret_sts=$?
if [[ ${ret_sts} -ne 0 ]]; then
  echo "rndc sync-clean FAILED! Error code $retsts; aborted."
  exit $retsts
fi
echo "Signing on '$PUBLIC_DOMAIN_FQDN' zone in view 'red'..."
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" sign "$PUBLIC_DOMAIN_FQDN" in red
ret_sts=$?
if [[ ${ret_sts} -ne 0 ]]; then
  echo "rndc sign $PUBLIC_DOMAIN_FQDN in red: Error code $retsts; aborted."
  exit $retsts
fi
echo "Signing on '$PUBLIC_DOMAIN_FQDN' zone ..."
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" sign "$PUBLIC_DOMAIN_FQDN"
ret_sts=$?
if [[ ${ret_sts} -ne 0 ]]; then
  echo "rndc sign $PUBLIC_DOMAIN_FQDN: Error code $retsts; aborted."
  exit $retsts
fi
echo "Notifying master server for '$PUBLIC_DOMAIN_FQDN' zone ..."
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" notify "$PUBLIC_DOMAIN_FQDN"
ret_sts=$?
if [[ ${ret_sts} -ne 0 ]]; then
  echo "rndc notify $PUBLIC_DOMAIN_FQDN: Error code $retsts; aborted."
  exit $retsts
fi
rm -f /var/lib/bind/*.jnl
rm -f /var/cache/bind/*.jnl


# Close Bind
echo "Stopping all DNS servers..."
systemctl stop bind9.service

# Clean up any files
echo "Cleaning up files ..."
rm -f /var/lib/bind/slave/*.slave

# Start then Bind


# these series of 'rm' is needed until BIND 9.12+
rm -f /var/cache/bind/*.jbk

rm -f /var/lib/bind/*.jnl
rm -f /var/lib/bind/*.signed
rm -f /var/lib/bind/master/*.jnl
rm -f /var/lib/bind/master/*.signed
rm -f /var/lib/bind/slave/*.jnl
rm -f /var/lib/bind/slave/*.signed
rm -f /var/lib/bind/dynamic/*.jnl
rm -f /var/lib/bind/dynamic/*.signed

echo "Starting up bind9.service"
systemctl start bind9.service
RET_STS=$?
if [[ ${RET_STS} -ne 0 ]]; then
  echo "Error in starting bind9.service; fix that firstly..."
  exit ${RET_STS}
fi

# Check status of then Bind
echo "Checking on status of bind9.service"
systemctl status -l --lines=20 --no-pager bind9.service

sleep 2
# Inform downstream (slaves and hidden master) nameservers of new zone update
echo "rndc $PUBLIC_RNDC_OPT -c $PUBLIC_RNDC_CONF retransfer $PUBLIC_DOMAIN_FQDN"
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" retransfer "$PUBLIC_DOMAIN_FQDN"
ret_sts=$?
if [[ ${ret_sts} -ne 0 ]]; then
  echo "rndc retransfer $PUBLIC_DOMAIN_FQDN: Error code $retsts; aborted."
  exit $retsts
fi

# Probably can only do 'zonestatus' on master/primary, not slave/secondary here
echo "rndc $PUBLIC_RNDC_OPT -c $PUBLIC_RNDC_CONF zonestatus $PUBLIC_DOMAIN_FQDN"
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" zonestatus "$PUBLIC_DOMAIN_FQDN"
ret_sts=$?
if [[ ${ret_sts} -ne 0 ]]; then
  echo "rndc zonestatus $PUBLIC_DOMAIN_FQDN: Error code $retsts; aborted."
  exit $retsts
fi
echo

# This echo command below erases the RETSTS/$? from previous commands
echo "End of $0"


