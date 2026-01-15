create database verifierdb;
create user 'verifier'@'localhost' identified by 'fire';
grant all on verifierdb.* to 'verifier'@'localhost';
create database registrardb;
create user 'registrar'@'localhost' identified by 'regi';
grant all on registrardb.* to 'registrar'@'localhost';
