#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin

# Vers: 1.1 beta
# Date: 10/17/2020
# Based on: https://github.com/thrnz/docker-wireguard-pia/blob/master/extra/pf.sh
# Dependencies: xmlstarlet jq
# Compatibility: pfSense 2.4>
# Before starting setup PIA following this guide: https://blog.networkprofile.org/private-internet-access-vpn-on-pfsense/

####### Adjust all of the following variables #######

# PIA Credentials
# Only use if you don't obtain the token manually
#piauser='PIAuser'
#piapass='PIApassword'

# qBitTorrent API Credentials
qbtuser='qbtuser'
qbtpass='qbtpass'
qbtapiport='8123'

# OpenVPN interface name
ovpniface='ovpnc2'

# Alias names for qBitTorrent IP and PORT
ipalias='TorrentingServer'
portalias='TorrentingPort'

######################## MAIN #########################
# Wait for VPN interface to get fully UP
# Increase this if you have very slow connection or connecting to PIA servers with huge response times
sleep 1

# pfSense config file and tempconfig location
conffile='/cf/conf/config.xml'
tmpconffile='/tmp/tmpconfig.xml'

# Fetch remote qBitTorrent IP from config
qbtip=$(xml sel -t -v "//alias[name=\"$ipalias\"]/address" $conffile)

###### Nextgen PIA port forwarding #######
# If your connection is unstable you might need to adjust these.
curl_max_time=15
curl_retry=5
curl_retry_delay=15

# Get PIA authorization token
# get_auth_token () {
#   tok=$(curl --interface ${ovpniface} --insecure --silent --show-error --fail --request POST --max-time $curl_max_time \
#     --header "Content-Type: application/json" \
#     --data "{\"username\":\"$piauser\",\"password\":\"$piapass\"}" \
#     "https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')
#   tok_rc=$?
#   if [ "$tok_rc" -ne 0 ]; then
#     logger "[PIA-API] Error! Failed to acquire auth token!"
#     exit 1
#   fi
# }

# This curl request can be ran once, outside the script and the token is manually set here
# This way you don't need your PIA username and password to be stored in the script

# Optionally you can uncomment it and let it run automatically, in which case you need to
# set the piauser and piapassword variables at the beginning.
tok="your_token"

get_sig () {
  pf_getsig=$(curl --interface ${ovpniface} --insecure --get --silent --show-error --fail \
    --retry $curl_retry --retry-delay $curl_retry_delay --max-time $curl_max_time \
    --data-urlencode "token=$tok" \
    "https://$pf_host:19999/getSignature")
  if [ "$(echo "$pf_getsig" | jq -r .status)" != "OK" ]; then
    logger "[PIA-API] Error! Failed to receive Signature!"
    exit 1
  fi
  pf_payload=$(echo "$pf_getsig" | jq -r .payload)
  pf_signature=$(echo "$pf_getsig" | jq -r .signature)
  pf_port=$(echo "$pf_payload" | b64decode -r | jq -r .port)
  pf_signature_expiry_raw=$(echo "$pf_payload" | b64decode -r | jq -r .expires_at)
  pf_signature_expiry=$(date -jf %Y-%m-%dT%H:%M:%S "$pf_signature_expiry_raw" +%s)
}

bind_port () {
  pf_bind=$(curl --interface ${ovpniface} --insecure --get --silent --show-error --fail \
    --retry $curl_retry --retry-delay $curl_retry_delay --max-time $curl_max_time \
    --data-urlencode "payload=$pf_payload" \
    --data-urlencode "signature=$pf_signature" \
    "https://$pf_host:19999/bindPort")
  if [ "$(echo "$pf_bind" | jq -r .status)" != "OK" ]; then
    logger "[PIA-API] Error! Failed to bind received port!"
    exit 1
  fi
}

# Rebind every 15 mins (same as desktop app)
pf_bindinterval=$(( 15 * 60))

# Get a new signature when the current one has less than this remaining
# Defaults to 7 days (same as desktop app)
pf_minreuse=$(( 60 * 60 * 24 * 7 ))

# Get the IP of the VPN server we're connected to
pf_host=$(ifconfig ovpnc2 | grep -E 'inet ' | cut -d ' ' -f4)

pf_remaining=0
log_cycle=0
reloadcfg=0

while true; do
  pf_remaining=$(( pf_signature_expiry - $(date +%s) ))
  if [ $pf_remaining -lt $pf_minreuse ]; then
    # Get a new pf signature as the previous one will expire soon
    get_sig
    bind_port
  fi
  
  # Some checks that we received valid port number and not some garbage.
  if [ -z "$pf_port" ]; then
    pf_port='0'
    logger "[PIA] You are not connected to a PIA region that supports port forwarding. Aborting..."
    exit 1
  elif ! [ "$pf_port" -eq "$pf_port" ] 2> /dev/null; then
    logger "[PIA] Fatal error! Value $pf_port is not a number. PIA API has most probably changed. Manual check necessary."
    exit 1
  elif [ "$pf_port" -lt 1024 ] || [ "$pf_port" -gt 65535 ]; then
    logger "[PIA] Fatal error! Value $pf_port outside allowed port range. PIA API has most probably changed. Manual check necessary."
    exit 1
  fi
  
  # Get current NAT port number using xmlstarlet to parse the config file.
  natport=$(xml sel -t -v "//alias[name=\"$portalias\"]/address" $conffile)

  # If the acquired port is the same as already configured do not pointlessly reload config.
  if [ "$natport" -eq "$pf_port" ]; then
    reloadcfg=0
    logger "[PIA] Acquired port $pf_port equals the already configured port $natport - no action required."
	else
    # If the port has changed update the tempconfig file and reset the log cycle.
    logger "[PIA] Acquired NEW forwarding port: $pf_port, current NAT rule port: $natport"
    xml ed -u "//alias[name=\"$portalias\"]/address" -v $pf_port $conffile > $tmpconffile
    log_cycle=0
    reloadcfg=1
  fi

  if [ "$reloadcfg" -eq 1 ]; then
    # Validate the XML file just to ensure we don't nuke whole configuration
    xml val -q $tmpconffile
    xmlval=$?
    if [ "$xmlval" -gt 0 ]; then
	    logger "[PIA] Fatal error! Updated tempconf file $tmpconffile does not have valid XML format. Verify that the port alias is correct in script header and exists in pfSense Alias list"
	    exit 1
    fi

    # If the updated tempconfig is valid and the port changed update and reload config
    cp $conffile ${conffile}.bck
    cp $tmpconffile $conffile
    # Force pfSense to re-read it's config and reload the rules.
    rm /tmp/config.cache
    /etc/rc.filter_configure
    logger "[PIA] New port $pf_port updated in pfSense config file."
  fi

  ###### Remote update of the qBitTorrent port #######

  # Only update if necessary
  if [ "$reloadcfg" -eq 1 ]; then
    # Check if qBitTorrent is running and API is accesible
    curl --silent --connect-timeout 10 "http://$qbtip:$qbtapiport/" > /dev/null
    curlrc=$?
    if [ "$curlrc" -gt 0 ]; then
      logger "[qbt] Error! qBitTorrent service is NOT reachable on $qbtip port $qbtapiport"
    else
      # Login to the API
      login_result=$(curl --silent --show-error --fail \
      --data "username=$qbtuser&password=$qbtpass" --cookie-jar /tmp/qbt_api_token \
      "http://$qbtip:$qbtapiport/api/v2/auth/login")
      if [ "$login_result" != "Ok." ]; then
        logger "[qbt] Error! qBitTorrent API Login Failed. Please check credentials."
      else
        # Change qBitTorrent Port
        curl --silent --show-error --fail --cookie /tmp/qbt_api_token \
        --data "json={\"listen_port\":\"$pf_port\"}" \
        "http://$qbtip:$qbtapiport/api/v2/app/setPreferences"
        curlrc=$?
        if [ "$curlrc" -gt 0 ]; then
          logger "[qbt] Error when updating listen port! Please check API"
        else
          logger "[qbt] Successfully updated listen port to $pf_port"
        fi
        # Logout from qBitTorrent API
        curl --silent --show-error --fail --cookie /tmp/qbt_api_token \
        "http://$qbtip:$qbtapiport/api/v2/auth/logout"
      fi
    fi
  fi

  sleep $pf_bindinterval &
  wait $!
  bind_port

done
