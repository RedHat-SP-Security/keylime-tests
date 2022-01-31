create database verifierdb;
create user verifier identified by 'fire';
grant all on verifierdb.* to verifier;
create database registrardb;
create user registrar identified by 'regi';
grant all on registrardb.* to registrar;
