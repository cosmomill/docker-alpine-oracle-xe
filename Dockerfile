FROM cosmomill/alpine-glibc

MAINTAINER Rene Kanzler, me at renekanzler dot com

# add bash to make sure our scripts will run smoothly
RUN apk --update add --no-cache bash

# install bsdtar
RUN apk --update add --no-cache libarchive-tools

ONBUILD ARG ORACLE_RPM

ENV ORACLE_MAJOR 11.2.0
ENV ORACLE_VERSION 11.2.0-1.0
ENV ORACLE_BASE /u01/app/oracle
ENV ORACLE_HOME /u01/app/oracle/product/$ORACLE_MAJOR/xe
ENV ORACLE_SID XE
ENV PATH $PATH:$ORACLE_HOME/bin

RUN mkdir /docker-entrypoint-initdb.d

# install Oracle XE prerequisites
RUN apk --update add --no-cache libaio bc net-tools

# install Oracle XE
ONBUILD ADD $ORACLE_RPM /tmp/
ONBUILD RUN bsdtar -C /tmp -xf /tmp/oracle-xe-$ORACLE_VERSION.x86_64.rpm.zip && bsdtar -C / -xf /tmp/Disk1/oracle-xe-$ORACLE_VERSION.x86_64.rpm \
	&& cp /tmp/Disk1/response/xe.rsp /tmp/ \
	&& rm -rf /tmp/Disk1 \
	&& rm -f /tmp/oracle-xe-$ORACLE_VERSION.x86_64.rpm.zip

# add Oracle user and group
ONBUILD RUN addgroup dba && adduser -D -G dba -h /u01/app/oracle -s /bin/false oracle

# fix postScripts.sql
ONBUILD RUN sed -i "s|%ORACLE_HOME%|/u01/app/oracle/product/11.2.0/xe|" $ORACLE_HOME/config/scripts/postScripts.sql \
	\
# fix permissions
	&& chown -R oracle:dba /u01 \
	&& chmod 755 /etc/init.d/oracle-xe \
	&& find $ORACLE_HOME/config/scripts -type f -exec chmod 644 {} \; \
	&& find $ORACLE_HOME/config/scripts -name *.sh -type f -exec chmod 755 {} \; \
	&& find $ORACLE_HOME/bin -type f -exec chmod 755 {} \; \
	\
# set sticky bit to oracle executable
	&& chmod 6751 $ORACLE_HOME/bin/oracle \
	\
# create missing log directory
	&& install -d -o oracle -g dba $ORACLE_HOME/config/log \
	\
# create sysconfig directory
	&& install -d /etc/sysconfig \
	\
# fix paths in init script
	&& sed -i "s|/bin/awk|/usr/bin/awk|" /etc/init.d/oracle-xe \
	&& sed -i "s|/var/lock/subsys|/var/run|" /etc/init.d/oracle-xe \
	\
# add oracle environment variables
	&& ln -s $ORACLE_HOME/bin/oracle_env.sh /etc/profile.d/oracle_env.sh

# add alias conndba
RUN echo "alias conndba='su -s \"/bin/bash\" oracle -c \"sqlplus / as sysdba\"'" >> /etc/profile

# define mountable directories
ONBUILD VOLUME $ORACLE_BASE/oradata $ORACLE_HOME/apex/images

ENV PROCESSES 500
ENV SESSIONS 555
ENV TRANSACTIONS 610

COPY docker-apex-update.sh /usr/local/bin/
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh && chmod 755 /usr/local/bin/docker-apex-update.sh
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 1521 8080
CMD [""]
