CREATE TABLESPACE @@@DB_TABLESPACE@@@ DATAFILE '/opt/oracle/product/19c/dbhome_1/dbs/@@@DB_TABLESPACE@@@_01.dbf' SIZE 1000M autoextend on next 100m maxsize unlimited;


create user @@@DB_USER@@@ identified by @@@DB_PASS@@@ default tablespace @@@DB_TABLESPACE@@@ temporary tablespace temp;
GRANT SELECT ANY TABLE to 	@@@DB_USER@@@  ;
GRANT UNLIMITED TABLESPACE to 	@@@DB_USER@@@  ;
GRANT UPDATE ANY TABLE to 	@@@DB_USER@@@     ;
GRANT RESOURCE to 	@@@DB_USER@@@     ;
GRANT CONNECT to 	@@@DB_USER@@@     ;
GRANT CREATE table to 	@@@DB_USER@@@     ;
GRANT CREATE SESSION to 	@@@DB_USER@@@     ;
GRANT CREATE ANY INDEX to 	@@@DB_USER@@@     ;
grant query rewrite to 	@@@DB_USER@@@     ;
grant execute any procedure to 	@@@DB_USER@@@     ;
 grant create view  to 	@@@DB_USER@@@     ;
grant create sequence to 	@@@DB_USER@@@     ;

