#!/bin/bash
###
# Lib to ease CI scripts

HERE=$(cd $(dirname $0); pwd -P)
JVM_XMX=${JVM_XMX:-1g}
NXVERSION=${NXVERSION:-5.4}
NXDISTRIBUTION="$HERE/nuxeo-distribution-$NXVERSION"
JBOSS_HOME="$HERE/jboss"
TOMCAT_HOME="$HERE/tomcat"
SERVER=${SERVER:-jboss}

if [ "$SERVER" = "tomcat" ]; then
    SERVER_HOME="$TOMCAT_HOME"
    TOMCAT_LIB="$TOMCAT_HOME/lib"
    SERVER_LIB="$TOMCAT_LIB"
else
    SERVER_HOME="$JBOSS_HOME"
    JBOSS_LIB="$JBOSS_HOME/server/default/lib"
    SERVER_LIB="$JBOSS_LIB"
fi

# include dblib
. $HERE/integration-dblib.sh

check_ports_and_kill_ghost_process() {
    hostname=${1:-0.0.0.0}
    ports=${2:-8080 14440}
    for port in $ports; do
      RUNNING_PID=`lsof -n -i TCP@$hostname:$port | grep '(LISTEN)' | awk '{print $2}'`
      if [ ! -z $RUNNING_PID ]; then 
          echo [WARN] A process is already using port $port: $RUNNING_PID
          echo [WARN] Storing jstack in $PWD/$RUNNING_PID.jstack then killing process
          [ -e /usr/lib/jvm/java-6-sun/bin/jstack ] && /usr/lib/jvm/java-6-sun/bin/jstack $RUNNING_PID >$PWD/$RUNNING_PID.jstack
          kill $RUNNING_PID || true
          sleep 5
          kill -9 $RUNNING_PID || true
      fi
    done
}

update_distribution_source() {
    if [ ! -d "$NXDISTRIBUTION" ]; then
        hg clone -r $NXVERSION http://hg.nuxeo.org/nuxeo/nuxeo-distribution "$NXDISTRIBUTION" 2>/dev/null || exit 1
    else
        (cd "$NXDISTRIBUTION" && hg pull && hg up -C $NXVERSION) || exit 1
    fi
}

build_jboss() {
    # should detect when it's necessary to rebuild JBoss (libraries or source code changed)
    (cd "$NXDISTRIBUTION" && mvn clean install -Pnuxeo-dm,cmis,jboss,nuxeo-dm-jboss) || exit 1
}

build_jboss_ep() {
    echo "DEPRECATED - Use Nuxeo CAP instead of EP"
}

build_cap() {
    (cd "$NXDISTRIBUTION" && mvn install -Pnuxeo-cap,$SERVER) || exit 1
}

set_jboss_log4j_level() {
    JBOSS=$1
    shift
    LEVEL=$1
    shift
    sed -i "/<root>/,/root>/ s,<level value=.*\$,<level value=\"$LEVEL\"/>," "$JBOSS"/server/default/conf/jboss-log4j.xml
}

setup_server_conf() {
    SERVER_HOME=${1:-"$SERVER_HOME"}
    MAIL_FROM=${MAIL_FROM:-`dirname $PWD|xargs basename`@$HOSTNAME}
    cat >> "$SERVER_HOME"/bin/nuxeo.conf <<EOF || exit 1
nuxeo.templates=default,monitor
nuxeo.bind.address=$IP
mail.smtp.host=merguez.in.nuxeo.com
mail.smtp.port=2500
mail.from=$MAIL_FROM
JAVA_OPTS=-server -Xms$JVM_XMX -Xmx$JVM_XMX -XX:MaxPermSize=512m \
  -Dsun.rmi.dgc.client.gcInterval=3600000 -Dsun.rmi.dgc.server.gcInterval=3600000 \
  -Xloggc:\$DIRNAME/../log/gc.log  -verbose:gc -XX:+PrintGCDetails \
  -XX:+PrintGCTimeStamps
EOF
    chmod u+x "$SERVER_HOME"/bin/*.sh "$SERVER_HOME"/bin/*ctl 2>/dev/null
    
    if [ "$SERVER" = jboss ]; then
        set_jboss_log4j_level $SERVER_HOME INFO
        echo "org.nuxeo.systemlog.token=dolog" > "$SERVER_HOME"/templates/common/config/selenium.properties
        mkdir -p "$SERVER_HOME"/log
    fi
    if [ "$SERVER" = tomcat ]; then
        echo "org.nuxeo.systemlog.token=dolog" > "$TOMCAT"/nxserver/config/selenium.properties
    fi
}

setup_jboss() {
    if [ $# == 2 ]; then
        JBOSS="$1"
        shift
    else
        JBOSS="$JBOSS_HOME"
    fi
    IP=${1:-0.0.0.0}
    if [ ! -d "$JBOSS" ] || [ ! -z $NEW_JBOSS ] ; then
        [ -d "$JBOSS" ] && rm -rf "$JBOSS"
        cp -r "$NXDISTRIBUTION"/nuxeo-distribution-jboss/target/*$PRODUCT*jboss "$JBOSS" || exit 1
    else
        echo "Using previously installed JBoss. Set NEW_JBOSS variable to force new JBOSS deployment"
        rm -rf "$JBOSS"/server/default/data/* "$JBOSS"/log/*
    fi
    mkdir -p "$JBOSS"/log
    setup_server_conf $JBOSS
}

build_tomcat() {
    (cd "$NXDISTRIBUTION" && mvn clean install -Ptomcat) || exit 1
}

setup_tomcat() {
    if [ $# == 2 ]; then
        TOMCAT="$1"
        shift
    else
        TOMCAT="$TOMCAT_HOME"
    fi
    IP=${1:-0.0.0.0}
    if [ ! -d "$TOMCAT" ] || [ ! -z $NEW_TOMCAT ] ; then
        [ -d "$TOMCAT" ] && rm -rf "$TOMCAT"
        unzip "$NXDISTRIBUTION"/nuxeo-distribution-tomcat/target/nuxeo-distribution-tomcat-*$PRODUCT.zip -d /tmp/ \
        && mv /tmp/*$PRODUCT*-tomcat "$TOMCAT" || exit 1
    else
        echo "Using previously installed Tomcat. Set NEW_TOMCAT variable to force new TOMCAT deployment"
        rm -rf "$TOMCAT"/webapps/nuxeo/nxserver/data/* "$TOMCAT"/log/*
    fi
    setup_server_conf $TOMCAT
}

deploy_ear() {
  JBOSS=${1:-$JBOSS_HOME}
  if [ ! -d "$JBOSS"/server/default/deploy/nuxeo.ear ] || [ -z $NEW_JBOSS ] ; then
    deploySRCtoDST "$NXDISTRIBUTION"/nuxeo-distribution-jboss/target/nuxeo-dm-jboss/server/default/deploy/nuxeo.ear "$JBOSS"/server/default/deploy/nuxeo.ear
  else
    echo "Using EAR already present in JBoss assuming it's a fresh build."
  fi
}

deploySRCtoDST() {
  SRC=$1
  DST=$2
  [ -d "$DST" ] && rm -rf "$DST"
  cp -r $SRC $DST
}

start_server() {
    if [ $# == 2 ]; then
        SERVER_HOME="$1"
        shift
    fi
    IP=${1:-0.0.0.0}
    check_ports_and_kill_ghost_process $IP
    "$SERVER_HOME"/bin/nuxeoctl start || exit 1
    "$SERVER_HOME"/bin/monitorctl.sh start
}

stop_server() {
    SERVER_HOME=${1:-"$SERVER_HOME"}
    "$SERVER_HOME"/bin/monitorctl.sh stop
    "$SERVER_HOME"/bin/nuxeoctl stop
    if [ ! -z $PGPASSWORD ]; then
        "$SERVER_HOME"/bin/monitorctl.sh vacuumdb
    fi
    echo "### 10 most frequent errors --------------"
    grep " ERROR \[" "$SERVER_HOME"/log/server.log | sed "s/^.\{24\}//g" | sort | uniq -c | sort -nr | head
    echo "### 10 first errors ----------------------"
    grep -nTm 10 " ERROR " "$SERVER_HOME"/log/server.log
    echo "### --------------------------------------"
    gzip "$SERVER_HOME"/log/*.log
    gzip -cd  "$SERVER_HOME"/log/server.log.gz 2>/dev/null > "$SERVER_HOME"/log/server.log
}
