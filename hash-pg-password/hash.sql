SET password_encryption='scram-sha-256';
CREATE ROLE x PASSWORD :pw;
SELECT rolpassword FROM pg_authid WHERE rolname='x';
