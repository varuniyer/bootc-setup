\set hash `cat`
CREATE ROLE experiments LOGIN PASSWORD :'hash';
CREATE DATABASE experiments OWNER experiments;
REVOKE CONNECT, TEMPORARY ON DATABASE postgres, template1, experiments FROM PUBLIC;
