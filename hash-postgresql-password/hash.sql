-- cat keeps the password off psql's argv.
\set pw `cat`
CREATE ROLE experiments PASSWORD :'pw';
SELECT rolpassword FROM pg_authid WHERE rolname='experiments';
