-- cat reads the password from stdin, so it stays off psql's argv.
\set pw `cat`
CREATE ROLE x PASSWORD :'pw';
SELECT rolpassword FROM pg_authid WHERE rolname='x';
