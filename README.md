Alpine Oracle Database 11g Express Edition Docker image
=======================================================

This image is based on Alpine GNU C library image ([cosmomill/alpine-glibc](https://hub.docker.com/r/cosmomill/alpine-glibc/)), which is only a 5MB image, and provides a docker image for Oracle Database 11g Release 2 Express Edition.

Prerequisites
-------------

If you want to build this image, you will need to download [Oracle Database 11g Release 2 Express Edition for Linux x64](http://www.oracle.com/technetwork/database/database-technologies/express-edition/downloads/index.html).
Oracle Database 11g Release 2 Express Edition requires Docker 1.10.0 and above. *(Docker supports --shm-size since Docker 1.10.0)*
Oracle Database 11g Release 2 Express Edition uses shared memory for MEMORY_TARGET and needs at least 1 GB.

Usage Example
-------------

This image is intended to be a base image for your projects, so you may use it like this:

```Dockerfile
FROM cosmomill/alpine-oracle-xe

# Optional, auto import of sh, sql and dmp files at first startup
ADD my_schema.sql /docker-entrypoint-initdb.d/
```

```sh
$ docker build -t my_app . --build-arg ORACLE_RPM="oracle-xe-11.2.0-1.0.x86_64.rpm.zip"
```

```sh
$ docker run -d -P --shm-size=1g -v db_data:/u01/app/oracle/oradata -v apex_images:/u01/app/oracle/product/11.2.0/xe/apex/images -p 1521:1521 -p 8080:8080 my_app
```

Connect to database
-------------------

Auto generated passwords are stored in separate hidden files in ```/u01/app/oracle/oradata/dbconfig/XE``` with the naming system ```.username.passwd```.
