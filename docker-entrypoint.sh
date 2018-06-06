#!/bin/bash

# move DB files
function moveFiles {
	if [ ! -d $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID ]; then
		mkdir -p $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	fi;

	mv $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv $ORACLE_HOME/dbs/orapw$ORACLE_SID $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv $ORACLE_HOME/network/admin/listener.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv /etc/sysconfig/oracle-xe $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/

	chown -R oracle:dba $ORACLE_BASE/oradata/dbconfig

	symLinkFiles;
}

# symbolic link DB files
function symLinkFiles {
	if [ ! -L $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/spfile$ORACLE_SID.ora $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora
	fi;

	if [ ! -L $ORACLE_HOME/dbs/orapw$ORACLE_SID ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/orapw$ORACLE_SID $ORACLE_HOME/dbs/orapw$ORACLE_SID
	fi;

	if [ ! -L $ORACLE_HOME/network/admin/tnsnames.ora ]; then
		ln -sf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora
	fi;

	if [ ! -L $ORACLE_HOME/network/admin/listener.ora ]; then
		ln -sf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/listener.ora $ORACLE_HOME/network/admin/listener.ora
	fi;

	if [ ! -L /etc/sysconfig/oracle-xe ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oracle-xe /etc/sysconfig/oracle-xe
	fi;
}

# import oracle dumps
function impdp () {
	DUMP_FILE=$(basename "$1")
	DUMP_NAME=${DUMP_FILE%.dmp}

	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      -- create IMPDP user
      create user IMPDP identified by IMPDP;
      alter user IMPDP account unlock;
      grant DBA to IMPDP with admin option;
      -- create new scheme user
      create or replace directory IMPDP as '$DOCKER_BUILD_FOLDER/docker-entrypoint-initdb.d';
      create tablespace $DUMP_NAME datafile '$ORACLE_BASE/oradata/$ORACLE_SID/$DUMP_NAME.dbf' size 10m autoextend on next 1m maxsize unlimited;
      create user $DUMP_NAME
      identified by \"$DUMP_NAME\"
      default tablespace $DUMP_NAME
      temporary tablespace TEMP
      quota unlimited on $DUMP_NAME;
      alter user $DUMP_NAME default role all;
      grant connect, resource to $DUMP_NAME;
      exit;
EOF"

	su -s /bin/bash oracle -c "impdp IMPDP/IMPDP directory=IMPDP dumpfile=$DUMP_FILE nologfile=y"

	# disable IMPDP user
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      ALTER USER IMPDP ACCOUNT LOCK;
      exit;
EOF"
}

# SIGTERM handler
function _term() {
	echo "Stopping container."
	echo "SIGTERM received, shutting down database!"
	/etc/init.d/oracle-xe stop
}

# SIGKILL handler
function _kill() {
	echo "SIGKILL received, shutting down database!"
	/etc/init.d/oracle-xe stop
}

# create DB
function createDB {
	# setting up memory
	AVAILPHYMEM=`cat /proc/meminfo | grep '^MemTotal' | awk '{print $2}'`
	AVAILPHYMEM=`echo $AVAILPHYMEM / 1024 | bc`
	MEMORY_TARGET=`echo 0.40 \* $AVAILPHYMEM | bc | sed "s/\..*//"`

	if [ $MEMORY_TARGET -gt 1024 ]; then
		MEMORY_TARGET=`echo 1024 \* 1048576 | bc`
	else
		MEMORY_TARGET=`echo $MEMORY_TARGET \* 1048576 | bc`
	fi;

	sed -i "s/%memory_target%/$MEMORY_TARGET/g" $ORACLE_HOME/config/scripts/init.ora
	sed -i "s/%memory_target%/$MEMORY_TARGET/g" $ORACLE_HOME/config/scripts/initXETemp.ora

	# setting up processes, sessions, transactions
	printf "Setting up:\nprocesses=$PROCESSES\nsessions=$SESSIONS\ntransactions=$TRANSACTIONS\n"
	echo "If you want to use different parameters set processes, sessions, transactions env variables and consider this formula:"
	printf "processes=x\nsessions=x*1.1+5\ntransactions=sessions*1.1\n"

	sed -i -E "s/sessions=[^)]+/sessions=$SESSIONS/g" $ORACLE_HOME/config/scripts/init.ora
	sed -i -E "s/sessions=[^)]+/sessions=$SESSIONS/g" $ORACLE_HOME/config/scripts/initXETemp.ora

	sed -i "/sessions=$SESSIONS/a processes=$PROCESSES" $ORACLE_HOME/config/scripts/init.ora
	sed -i "/sessions=$SESSIONS/a processes=$PROCESSES" $ORACLE_HOME/config/scripts/initXETemp.ora

	sed -i "/processes=$PROCESSES/a transactions=$TRANSACTIONS" $ORACLE_HOME/config/scripts/init.ora
	sed -i "/processes=$PROCESSES/a transactions=$TRANSACTIONS" $ORACLE_HOME/config/scripts/initXETemp.ora

	# auto generate SYSDBA password if not passed on
	SYSDBA_PWD=${SYSDBA_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}

	sed -i -e "s|<value required>|$SYSDBA_PWD|g" /tmp/xe.rsp && \
	/etc/init.d/oracle-xe configure responseFile=/tmp/xe.rsp && \
	rm /tmp/xe.rsp

	# listener 
	echo "LISTENER = \
  (DESCRIPTION_LIST = \
    (DESCRIPTION = \
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC_FOR_XE)) \
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521)) \
    ) \
  ) \
\
" > $ORACLE_HOME/network/admin/listener.ora

	# update tnsnames.ora to use localhost instead of the current hostname
	sed -i -r "s/\(HOST = [^)]+/\(HOST = localhost/" $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/tnsnames.ora

	echo "DEDICATED_THROUGH_BROKER_LISTENER=ON"  >> $ORACLE_HOME/network/admin/listener.ora && \
	echo "DIAG_ADR_ENABLED=OFF"  >> $ORACLE_HOME/network/admin/listener.ora;
	chown -R oracle:dba $ORACLE_HOME/network/admin/listener.ora

	# Oracle XE has SYSTEM as the default tablespace by default, set back to USERS
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      alter database default tablespace USERS;
      select * from database_properties where property_name = 'DEFAULT_PERMANENT_TABLESPACE';
      exit;
EOF"

	# don't expire passwords
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      alter profile default limit password_life_time unlimited;
      exit;
EOF"

	# move redo logs to mountable directory ($ORACLE_BASE/oradata)
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      EXEC DBMS_XDB.SETLISTENERLOCALACCESS(FALSE);

      alter database add logfile group 4 ('$ORACLE_BASE/oradata/$ORACLE_SID/redo04.log') size 50m;
      alter database add logfile group 5 ('$ORACLE_BASE/oradata/$ORACLE_SID/redo05.log') size 50m;
      alter database add logfile group 6 ('$ORACLE_BASE/oradata/$ORACLE_SID/redo06.log') size 50m;
      alter system switch logfile;
      alter system switch logfile;
      alter system checkpoint;
      alter database drop logfile group 1;
      alter database drop logfile group 2;

      alter system set db_recovery_file_dest='';
      exit;
EOF"

	# move database operational files to oradata
	moveFiles;

	# store SYSDBA password 
	SYSDBA_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.sysdba.passwd
	echo -n $SYSDBA_PWD > $SYSDBA_PWD_FILE
	chmod 600 $SYSDBA_PWD_FILE
	chown root:root $SYSDBA_PWD_FILE
}

# MAIN

# set SIGTERM handler
trap _term SIGTERM

# set SIGKILL handler
trap _kill SIGKILL

# prevent owner issues on mounted folders
chown -R oracle:dba $ORACLE_BASE/oradata

# check whether database already exists
if [ -d $ORACLE_BASE/oradata/$ORACLE_SID ]; then
	symLinkFiles;

	# make sure audit file destination exists
	if [ ! -d $ORACLE_BASE/admin/$ORACLE_SID/adump ]; then
		mkdir -p $ORACLE_BASE/admin/$ORACLE_SID/adump
		chown -R oracle:dba $ORACLE_BASE/admin/$ORACLE_SID/adump
	fi;
fi;

/etc/init.d/oracle-xe start | grep -qc "Oracle Database 11g Express Edition is not configured."
if [ "$?" == "0" ]; then
	# Check whether container has enough memory
	if [ `df -k /dev/shm | tail -n 1 | awk '{print $2}'` -lt 1048576 ]; then
		echo "Error: The container doesn't have enough memory allocated."
		echo "A database XE container needs at least 1 GB of shared memory (/dev/shm)."
		echo "You currently only have $((`df -k /dev/shm | tail -n 1 | awk '{print $2}'`/1024)) MB allocated to the container."
		exit 1;
	fi;

	# create database
	createDB;

	export RUN_INITDB=true

fi;

if [ $RUN_INITDB ]; then
	echo "Starting import from '/docker-entrypoint-initdb.d':"

	for f in /docker-entrypoint-initdb.d/*
	do
		case "$f" in
			*.sh)
				echo "$0: running $f"
				$f
				;;
			*.sql)
				echo "$0: running $f"
					su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
                      @$f
                      exit;
EOF"
				;;
			*.sql.gz)
				echo "$0: running $f"
				gunzip -c $f | su -s /bin/bash oracle -c "sqlplus -S / as sysdba"
				;;
			*.dmp)
				echo "$0: running $f"
				impdp $f
				;;
			*)
				echo "$0: ignoring $f"
				;;
		esac
	done
fi;

echo
echo "Oracle init process done. Database is ready to use."
echo

tail -f $ORACLE_BASE/diag/rdbms/*/*/trace/alert*.log &
CHILD_PID=$!
wait $CHILD_PID
