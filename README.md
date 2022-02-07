# safe-bind-dhcp-reset

Perform safe reload of ISC Bind9 and ISC DHCP, especially with dynamic zones inside a view.

There are two shell scripts:

1.  Perform bastion-host of DHCP with hidden-master restarting (bind-dhcp-reset.sh)
2.  Perform singular named daemon/server restarting (bind-reset.sh)
  - scripts figures out what to do
    - Ensure that named.conf is syntax-correct before proceeding.
    - Deterrmines what zones are declared (rndc reload)
    - Which zones are slave/hidden/stub or not (rndc refresh)
    - stops the named daemon
    - starts the named daemon
    - Whether re-sign is needed or not (DNSSEC, rndc sign)
    - Whether re-sign is needed or not (DNSSEC, rndc sign)
    - Display the zone details
   
    
