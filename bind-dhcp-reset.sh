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

# Debian Stretch/Woody/Sid/Bullseye filesystem convention
NAMED_ETC_DIR=/etc/bind

PUBLIC_DOMAIN_FQDN="egbert.net"
# PUBLIC_BIND_DIR="${NAMED_ETC_DIR}/public"
PUBLIC_NAMED_CONF="${NAMED_ETC_DIR}/named-public.conf"
PUBLIC_RNDC_CONF="${NAMED_ETC_DIR}/rndc-public.conf"
PUBLIC_RNDC_OPT="-p 954"
INTERNAL_DOMAIN_FQDN="leo"
# INTERNAL_BIND_DIR="${NAMED_ETC_DIR}/internal"
INTERNAL_NAMED_CONF="${NAMED_ETC_DIR}/named-internal.conf"
INTERNAL_RNDC_CONF="${NAMED_ETC_DIR}/rndc.conf"
INTERNAL_RNDC_OPT="-p 953"
INTERNAL_VIEWED_DYNAMIC_ZONE="green"

function check_systemctl_status() {
  SYSTEMD_UNIT_NAME=$1
  # Check status of DHCP server, Bind-Internal, then Bind-External
  systemctl status -l --lines=20 --no-pager "$SYSTEMD_UNIT_NAME"
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 ]]; then
    echo "Ouch; Starting up DHCP server failed"
    exit $RET_STS
  fi
}

function rndc_zonestatus_internal() {
  echo "Zone Status: Internal"
  rndc "$INTERNAL_RNDC_OPT" \
       -c "$INTERNAL_RNDC_CONF" \
            zonestatus "$INTERNAL_DOMAIN_FQDN"
}

function rndc_zonestatus_public() {
  echo "Zone Status: Public"
  rndc "$PUBLIC_RNDC_OPT" \
       -c "$PUBLIC_RNDC_CONF" \
       zonestatus "$PUBLIC_DOMAIN_FQDN"
}

function bdr_bind_files_remove() {
  # most of the removes here are for single Bind9 instantiation.
  rm -f /var/cache/bind/*.jbk
  rm -f /var/lib/bind/*.jnl
  rm -f /var/lib/bind/*.signed
}

function bdr_bind_files_remove_internal() {
  rm -f /var/cache/bind/internal/*.jbk
  # rm -f /var/lib/bind/internal/*.jnl
  # rm -f /var/lib/bind/internal/*.signed
  rm -f /var/lib/bind/internal/master/*.jnl
  rm -f /var/lib/bind/internal/master/*.signed
  rm -f /var/lib/bind/internal/slave/*.jnl
  rm -f /var/lib/bind/internal/slave/*.signed
  rm -f /var/lib/bind/internal/dynamic/*.jnl
  rm -f /var/lib/bind/internal/dynamic/*.signed
}

function bdr_bind_files_remove_public() {
  rm -f /var/cache/bind/public/*.jbk
  # rm -f /var/lib/bind/public/*.jnl
  # rm -f /var/lib/bind/public/*.signed
  rm -f /var/lib/bind/public/master/*.jnl
  rm -f /var/lib/bind/public/master/*.signed
  rm -f /var/lib/bind/public/slave/*.jnl
  rm -f /var/lib/bind/public/slave/*.signed
  rm -f /var/lib/bind/public/dynamic/*.jnl
  rm -f /var/lib/bind/public/dynamic/*.signed
}

function zone_slaves_retransfer() {
  # Now regather the zone statuses and note their master/slave ones
  zone_slaves_list internal
  # ZONES_SLAVE is returned
  for THIS_ZONE in $ZONES_SLAVE; do
    # Inform downstream (slaves) nameservers of  new  zones
    echo "Retransfering: Internal $THIS_ZONE slave zone"
    # Tell upstream master nameserver to do AXFR again
    rndc "$INTERNAL_RNDC_OPT" \
      -c "$INTERNAL_RNDC_CONF" \
      retransfer "$PUBLIC_DOMAIN_FQDN"
  done
}

# check_zone <zone-name> <class> <zone-db-file>
function check_zone_data() {
  NCZ_ARG_ZONENAME=$1
  NCZ_ARG_CONFIG=$2
  NCZ_ARG_ZONEFILE=$3
  echo "Performing named-checkzone -c $NCZ_ARG_CONFIG $NCZ_ARG_ZONENAME $NCZ_ARG_ZONEFILE..."
  named-checkzone \
    -i full \
    -S warn \
    -c "${NCZ_ARG_CONFIG}" \
    "${NCZ_ARG_ZONENAME}" "${NCZ_ARG_ZONEFILE}"
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 ]]; then
    echo "ERROR: Zone: $NCZ_ARG_ZONENAME File: $NCZ_ARG_CONFIG: Errno: $RET_STS"
    exit ${RET_STS}
  fi
}

# must_have_include <named.conf-path>
function must_have_include() {
  MHI_INCLUDE_FILE=$1
  # echo "Checking that named.conf is broken into many files via include statements..."
  INCLUDE_STATEMENT_COUNT="$(cat <"${MHI_INCLUDE_FILE}" | grep -E -c '^[[:space:]]*include ')"
  if [[ -z ${INCLUDE_STATEMENT_COUNT} ]]; then
    echo "No include statement found in $1"
    exit 2 # ENOENT
  fi
}

# add_any_include_files <filespec>
function add_any_include_files() {
  AAIF_ARG_CONF_FILE=$1
  # echo "Include statements: $INCLUDE_STATEMENT_COUNT"
  # Make a list of include statements to read
  INCLUDE_STATEMENTS="$(cat <"${AAIF_ARG_CONF_FILE}" | grep -E '^[[:space:]]*include ' | awk -F '"' '{print $2}')"
  # echo "add_any_include_files: $INCLUDE_STATEMENTS"
}

# reduce_include_files <list>
function reduce_include_files() {
  RET_INC_FILES=
  INC_FILES=$1
  for THIS_INC in ${INC_FILES}; do
    # echo "Checking if $THISINC has any zone/view statements..."
    # find any zone or view
    ZONES_FOUND="$(cat <"${THIS_INC}" | grep -E -c '^[[:space:]]*zone ')"
    ZONE_STATEMENT="$(cat <"${THIS_INC}" | grep -E '^[[:space:]]*zone ')"
    ZONENAME="$(echo "${ZONE_STATEMENT}" | awk -F ' ' '{print $2}' | sed -e 's/\"//g')"
    if [[ ${ZONES_FOUND} -gt 0 ]]; then
      SLAVE_FOUND="$(cat <"${THIS_INC}" | grep -E -c '^[[:space:]]*type[[:space:]]*slave[[:space:]]*;')"
      if [[ ${SLAVE_FOUND} -eq 0 ]]; then
        RET_INC_FILES="$RET_INC_FILES $THIS_INC"
        echo "zone $ZONENAME found in $THIS_INC"
      fi
    fi
  done
}

# check_conf <named.conf-path>
function check_conf() {
  NAMED_CONF=$1
  echo "Checking $NAMED_CONF named configuration file..."
  if [[ ! -r ${NAMED_CONF} ]]; then
    echo "File $NAMED_CONF is not readable: aborting..."
    exit 13 # ENOACCES
  fi
  must_have_include "$NAMED_CONF"
  add_any_include_files "$NAMED_CONF"
  ALL_INC_FILES="$INCLUDE_STATEMENTS"
  SEC_INC_FILES=

  # Scan through 2nd-nested each include statement for "include"
  for THIS_INC_FILE in ${ALL_INC_FILES}; do
    # echo "Finally processing 2nd-nested $THIS_INCFILE..."
    INC_FILES_FOUND="$(cat <"${THIS_INC_FILE}" | grep -E -c '^[[:space:]]*include ')"
    if [[ ${INC_FILES_FOUND} -gt 0 ]]; then
      # echo "Include(s) found in $THIS_INCFILE"
      add_any_include_files "$THIS_INC_FILE"
      ALL_INC_FILES="$ALL_INC_FILES $INCLUDE_STATEMENTS"
      SEC_INC_FILES="$SEC_INC_FILES $INCLUDE_STATEMENTS"
    fi
  done

  # Scan through 3rd-nested each include statement for "include"
  for THIS_INC_FILE in ${SEC_INC_FILES}; do
    # echo "Finally processing 3rd-nested $THIS_INCFILE..."
    INC_FILES_FOUND="$(cat <"${THIS_INC_FILE}" | grep -E -c '^[[:space:]]*include ')"
    if [[ ${INC_FILES_FOUND} -gt 0 ]]; then
      # echo "Include(s) found in $THIS_INCFILE"
      add_any_include_files "$THIS_INC_FILE"
      ALL_INC_FILES="$ALL_INC_FILES $INCLUDE_STATEMENTS"
    fi
  done
  # echo "All include files: $ALL_INCFILES"

  reduce_include_files "$ALL_INC_FILES"
  ALL_ZONE_CONFS="$RET_INC_FILES"
  # echo "Remaining include files having zone: $ALL_ZONE_CONFS"

  # We take list of named.conf files (or its include-derivative)
  # this assumes "file" statement is in same file as "zone" statement
  for THIS_ZONE_CONF in ${ALL_ZONE_CONFS}; do

    # and look for "zone" statement to submit to named-checkzone
    # extract zone name and if any its class as well
    ZONE_STATEMENT="$(cat <"${THIS_ZONE_CONF}" | grep -E '^[[:space:]]*zone ')"
    ZONENAME="$(echo "${ZONE_STATEMENT}" | awk -F ' ' '{print $2}' | sed -e 's/\"//g')"
    if [[ "$ZONENAME" == "." ]]; then
      continue
    fi
    CLASS_NAME="$(echo "${ZONE_STATEMENT}" | awk -F ' ' '{print $3}' | sed -e 's/://')"
    if [[ "$CLASS_NAME" == "{" ]]; then
      CLASS_NAME="IN"
    fi
    if [[ -z ${CLASS_NAME} ]]; then
      CLASS_NAME="IN"
    fi

    # and look for "file" statement to submit to named-checkzone
    FILE_FOUND="$(cat <"${THIS_ZONE_CONF}" | grep -E -c '^[[:space:]]*file ')"
    if [[ ${FILE_FOUND} -eq 0 ]]; then
      echo "No file statement found for Zone $ZONENAME "
      echo "    in file $THIS_ZONE_CONF"
      exit 1
    fi
    FILESPEC="$(cat <"${THIS_ZONE_CONF}" | grep -E '^[[:space:]]*file ' | awk -F '"' '{ print $2}')"
    check_zone_data "${ZONENAME}" ${CLASS_NAME} "$FILESPEC"
  done
  # returns VIEWS_LIST
  named-checkconf -zj "$NAMED_CONF"
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 ]]; then
    echo "named-checkconf $NAMED_CONF FAILED! Aborted."
    exit 5
  fi
}

# Check DHCPD conf
echo "Checking ISC dhcpd server configuration settings ..."
dhcpd -d -q -f -t
RET_STS=$?
if [[ ${RET_STS} -ne 0 ]]; then
  echo "DHCP configuration failed sanity check"
  exit ${RET_STS}
fi
if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
  echo "Checking ISC dhcpd server lease file ..."
  dhcpd -d -q -f -t -T
  RET_STS=$?
  if [[ ${RET_STS} -ne 0 ]]; then
    echo "DHCP lease failed sanity check"
    exit ${RET_STS}
  fi
fi

rndc "$INTERNAL_RNDC_OPT" -c "$INTERNAL_RNDC_CONF" reload
RET_STS=$?
if [[ ${RET_STS} -ne 0 && ${RET_STS} -ne 1 ]]; then
  echo "rndc failed to reload Internal DNS server"
  exit ${RET_STS}
fi
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" reload
RET_STS=$?
if [[ ${RET_STS} -ne 0 && ${RET_STS} -ne 1 ]]; then
  echo "rndc failed to reload Public DNS server"
  exit ${RET_STS}
fi

# Still a custom job to determine which zone (and view) to
#  unfreeze for Dynamic DNS

# Dynamic DNS is only used within Bind-Internal
# Unfreeze Bind-Internal
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" sync -clean
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" sign "$PUBLIC_DOMAIN_FQDN" in red
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" sign "$PUBLIC_DOMAIN_FQDN"
rndc "$PUBLIC_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" notify "$PUBLIC_DOMAIN_FQDN"
rndc "$INTERNAL_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" freeze "$INTERNAL_DOMAIN_FQDN" IN "$INTERNAL_VIEWED_DYNAMIC_ZONE"
########################rm -f /var/lib/bind/*.jnl
########################rm -f /var/cache/bind/*.jnl
rndc "$INTERNAL_RNDC_OPT" -c "$PUBLIC_RNDC_CONF" thaw "$INTERNAL_DOMAIN_FQDN" IN "$INTERNAL_VIEWED_DYNAMIC_ZONE"

# Close DHCP server, Bind-Internal, then Bind-External
echo "Stopping all DHCP client and DNS servers..."
systemctl stop dhclient@eth1.service
systemctl stop bind9-internal.service
systemctl stop bind9-public.service

# Clean up any files
rm -rf /var/lib/bind/internal/slave/*.slave # how were this *.slave got generated?

# Start DHCP server, Bind-Internal, then Bind-External
echo "Starting DHCP client"
systemctl start dhclient@eth1.service
RET_STS=$?
if [[ ${RET_STS} -ne 0 ]]; then
  echo "Error in DHCP client; fix that firstly..."
  exit ${RET_STS}
fi

# check the DHCP files using 'named-checkconf'
# Check namedconf
check_conf "$PUBLIC_NAMED_CONF"
check_conf "$INTERNAL_NAMED_CONF"

# these series of 'rm' is needed until BIND 9.12+
bdr_bind_files_remove
bdr_bind_files_remove_internal
bdr_bind_files_remove_public

# Now power up internal nameserver
systemctl start bind9-internal.service
RET_STS=$?
if [[ ${RET_STS} -ne 0 ]]; then
  echo "Error in starting bind9-internal.service; fix that firstly..."
  exit ${RET_STS}
fi

# Now power up external nameserver
systemctl start bind9-public.service
RET_STS=$?
if [[ ${RET_STS} -ne 0 ]]; then
  echo "Error in starting bind9-public.service; fix that firstly..."
  exit ${RET_STS}
fi

check_systemctl_status isc-dhcp-server.service
check_systemctl_status bind9-internal.service
check_systemctl_status bind9-public.service

# It takes time to start these babies up
sleep 2

# Now get the slaves to re-request AXFR zone upload again...
zone_slaves_retransfer

rndc_zonestatus_internal
rndc_zonestatus_public

# This echo command below erases the RETSTS/$? from previous commands
echo "End of $0"

# Might want to put this message out as a 'wall' message
# wall "$0: completed"
