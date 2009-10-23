#!/bin/bash -x

HERE=$(cd $(dirname $0); pwd -P)
. $HERE/integration-lib-new.sh

# create new Tomcat distribution each time as we don't have a build for nuxeo Tomcat webapp only
NEW_TOMCAT=true

# Cleaning
rm -rf ./tomcat ./results ./download
mkdir ./results ./download || exit 1

# Build
update_distribution_source

build_tomcat

setup_tomcat

# Setup PostgreSQL
if [ ! -z $PGPASSWORD ]; then
    setup_database
fi

# Start Nuxeo
start_tomcat

# Run selenium tests (not the webengine suite)
HIDE_FF=true URL=http://127.0.0.1:8080/nuxeo/ SUITES="suite1 suite2" "$NXDISTRIBUTION"/nuxeo-distribution-dm/ftest/selenium/run.sh
ret1=$?

# Stop Nuxeo
stop_tomcat

# Exit if some tests failed
[ $ret1 -eq 0 ] || exit 9