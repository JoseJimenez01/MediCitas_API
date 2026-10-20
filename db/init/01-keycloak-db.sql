-- Base de datos propia para Keycloak.
-- Ejecutado por la imagen oficial de PostgreSQL la PRIMERA vez que se inicializa el
-- volumen (docker-entrypoint-initdb.d). La base de la aplicacion (restaurantdb) la
-- crea POSTGRES_DB.
--
-- Separar las bases evita que el esquema de Keycloak (decenas de tablas) conviva con el
-- de la aplicacion: con EnsureCreatedAsync, si la base ya tiene tablas, EF Core asume
-- que el esquema existe y no crea la tabla "reservas".
CREATE DATABASE keycloakdb;