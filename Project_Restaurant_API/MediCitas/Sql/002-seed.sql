-- =====================================================================
-- MediCitas - SEED de datos masivos para analitica (dashboards)
--
-- Requisitos
--   * schema_medicitas.sql ya cargado y la base VACIA (el script aborta si hay clinicas).
--   * Ejecutar como SUPERUSUARIO (el RLS forzado bloquea al dueno de las tablas):
--         psql -d medicitas -v ON_ERROR_STOP=1 -f seed_medicitas.sql
--   * Es reproducible (setseed) y se genera con SQL por conjuntos: el archivo es pequeno
--     y la carga produce cientos de miles de filas.
--
-- Volumen aproximado
--   6 clinicas, 99 profesionales, ~36 mil pacientes, ~90 mil citas (mayo 2025 a la fecha de
--   ejecucion + 6 semanas a futuro), ~51 mil notas clinicas, ~140 mil registros de auditoria
--   y ~4 mil errores de procedimientos (~300 mil filas, ~100 MB). Tarda unos 3 minutos.
--
-- Como se carga: las citas historicas se insertan con el trigger de alta desactivado
-- (trg_cita_before_insert rechaza estados distintos de reservada y fechas pasadas) y se
-- reactiva al final. Las restricciones EXCLUDE, las FK compuestas y el resto de triggers
-- siguen activos, y al final se valida que ninguna cita viole el horario ni los bloqueos.
--
-- PATRONES SEMBRADOS (para validar los dashboards y sacar recomendaciones)
--   1. Tendencia: la demanda crece ~1.2% mensual; baja en diciembre/enero, Semana Santa y julio.
--   2. Estacionalidad semanal y horaria: lunes y mananas (9-11 h) con mas demanda; viernes,
--      sabado y la hora de almuerzo con menos. Las reservas se crean en horario laboral.
--   3. Clinica 4 (Cartago): ocupacion baja (~55%) y 35% mas cancelaciones.
--   4. Clinica 6 (Antigua) abre el 2026-01-15 con rampa de demanda; los profesionales nuevos
--      tambien tienen rampa de ~3 meses.
--   5. Clinica 2: caida de demanda en agosto de 2026 y mas cancelaciones por
--      "Profesional no disponible".
--   6. Clinica 5: campana marzo-abril 2026 (+25% de demanda).
--   7. Sobredemanda: Cardiologia (clinica 1) y Dermatologia (clinica 3) atienden ~30% mas citas
--      por profesional que la misma especialidad en otras clinicas.
--   8. ~12% de profesionales subutilizados; 3 profesionales dados de baja; ~8% de ingreso
--      reciente.
--   9. Ausentismo: mayor los lunes, en la primera hora, con anticipacion mayor a 14 dias,
--      en psicologia y en un grupo de pacientes de alto riesgo (reincidentes).
--  10. Cancelaciones crecen con la anticipacion de la reserva.
--  11. ~6% de citas reprogramadas (cadena origen -> sucesora una semana despues).
--  12. Cumplimiento de notas clinicas distinto por profesional (~10% con poca documentacion)
--      y notas tardias (dias despues de la cita).
--  13. Bloqueos de agenda (vacaciones, permisos, cierre de fin de ano) y bloqueos proximos
--      registrados despues de reservar: dejan citas reservadas en conflicto (RF6).
--  14. Auditoria con 3 anomalias: (a) recepcionista de la clinica 3 leyendo contactos de
--      madrugada (sep-oct 2026); (b) primer profesional de la clinica 1 leyendo notas de
--      colegas (oct 2026); (c) acceso masivo desde una IP externa en la clinica 5 el
--      2026-09-18 (recepcionista 1, 14:00-15:00).
--  15. Incidente 2026-08-12 14:00-16:00: rafaga de deadlocks y timeouts en reservas.
--  16. Algunos servicios con demanda desbalanceada (65% / 35%) dentro de cada especialidad.
-- =====================================================================
DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'Ejecutar el seed como superusuario (el RLS forzado bloquea al dueno de las tablas)';
    END IF;
    IF EXISTS (SELECT 1 FROM clinica) THEN
        RAISE EXCEPTION 'La base ya contiene datos: cargar el seed sobre un schema vacio';
    END IF;
END
$$;

BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT setseed(0.2026);
ALTER TABLE cita DISABLE TRIGGER trg_cita_before_insert;

-- ---------------------------------------------------------------------
-- 0. Funciones auxiliares temporales (se eliminan al cerrar la sesion)
-- ---------------------------------------------------------------------
CREATE FUNCTION pg_temp.pick(arr TEXT[], u FLOAT8) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$ SELECT arr[1 + floor(u * cardinality(arr))::int] $$;

CREATE FUNCTION pg_temp.nom_f(u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT pg_temp.pick(ARRAY['Maria','Ana','Sofia','Lucia','Valeria','Camila','Daniela','Paula','Carolina','Andrea',
 'Laura','Karla','Gabriela','Fernanda','Natalia','Mariana','Isabel','Rebeca','Silvia','Rocio','Monica',
 'Adriana','Patricia','Elena','Diana','Marcela','Tatiana','Julieta','Beatriz','Alejandra'], u) $$;

CREATE FUNCTION pg_temp.nom_m(u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT pg_temp.pick(ARRAY['Jose','Luis','Carlos','Diego','Andres','Mateo','Daniel','Javier','Jorge','Ricardo',
 'Fabian','Esteban','Mauricio','Sergio','Gerardo','Alonso','Roberto','Pablo','Marcos','Ivan','Oscar',
 'Felipe','Rafael','Hector','Adrian','Gabriel','Manuel','Kevin','Bryan','Alberto'], u) $$;

CREATE FUNCTION pg_temp.ape(u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT pg_temp.pick(ARRAY['Rodriguez','Gonzalez','Ramirez','Vargas','Mora','Jimenez','Solano','Quesada','Araya',
 'Chaves','Rojas','Castro','Salazar','Cordero','Alvarado','Brenes','Campos','Mendez','Vega','Picado','Segura',
 'Zuniga','Hernandez','Lopez','Perez','Morales','Ortiz','Navarro','Fonseca','Villalobos','Barrantes',
 'Esquivel','Monge','Arce','Cascante','Umana','Calderon','Rivera','Delgado','Aguilar'], u) $$;

-- grupo etario del paciente segun la especialidad: N = ninos, J = jovenes/adultos, M = 40+
CREATE FUNCTION pg_temp.grupo(e INT, u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT CASE e
    WHEN 1 THEN CASE WHEN u < 0.15 THEN 'N' WHEN u < 0.55 THEN 'J' ELSE 'M' END
    WHEN 2 THEN 'N'
    WHEN 3 THEN CASE WHEN u < 0.85 THEN 'M' ELSE 'J' END
    WHEN 4 THEN CASE WHEN u < 0.20 THEN 'N' WHEN u < 0.70 THEN 'J' ELSE 'M' END
    WHEN 5 THEN CASE WHEN u < 0.70 THEN 'J' ELSE 'M' END
    WHEN 6 THEN CASE WHEN u < 0.20 THEN 'N' WHEN u < 0.60 THEN 'J' ELSE 'M' END
    WHEN 7 THEN CASE WHEN u < 0.10 THEN 'N' WHEN u < 0.70 THEN 'J' ELSE 'M' END
    ELSE CASE WHEN u < 0.10 THEN 'N' WHEN u < 0.50 THEN 'J' ELSE 'M' END
END $$;

CREATE FUNCTION pg_temp.motivo(e INT, u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT pg_temp.pick(CASE e
    WHEN 1 THEN ARRAY['Control de hipertension arterial','Cuadro respiratorio agudo','Dolor lumbar mecanico','Control de diabetes tipo 2','Cefalea tensional','Chequeo preventivo anual']
    WHEN 2 THEN ARRAY['Control de crecimiento y desarrollo','Esquema de vacunacion','Fiebre de 48 horas','Otitis media aguda','Gastroenteritis leve','Dermatitis atopica']
    WHEN 3 THEN ARRAY['Palpitaciones ocasionales','Control de hipertension','Dolor toracico atipico','Seguimiento post infarto','Valoracion de riesgo cardiovascular','Disnea de esfuerzo']
    WHEN 4 THEN ARRAY['Acne inflamatorio','Dermatitis de contacto','Lunares para vigilancia','Psoriasis en placas','Verrugas virales','Urticaria cronica']
    WHEN 5 THEN ARRAY['Control ginecologico anual','Planificacion familiar','Control prenatal','Dismenorrea','Citologia de rutina','Climaterio']
    WHEN 6 THEN ARRAY['Limpieza y profilaxis','Caries molar','Dolor dental agudo','Control de ortodoncia','Extraccion de cordal','Tratamiento de conductos']
    WHEN 7 THEN ARRAY['Ansiedad generalizada','Estres laboral','Duelo','Trastorno del sueno','Terapia de pareja','Seguimiento de depresion leve']
    ELSE ARRAY['Plan de reduccion de peso','Control de glucosa','Dieta hipocalorica','Educacion alimentaria','Seguimiento de peso','Plan deportivo']
END, u) $$;

CREATE FUNCTION pg_temp.hallazgo(u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT pg_temp.pick(ARRAY['Signos vitales estables','Examen fisico sin hallazgos relevantes','Mejoria respecto a la consulta previa',
 'Parametros dentro del rango esperado','Se observa evolucion favorable','Requiere seguimiento cercano',
 'Sin signos de alarma','Hallazgos compatibles con el diagnostico'], u) $$;

CREATE FUNCTION pg_temp.plan(u FLOAT8) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
SELECT pg_temp.pick(ARRAY['Control en 4 semanas','Continuar tratamiento actual','Se solicitan examenes de laboratorio',
 'Se ajusta la medicacion','Referencia a otra especialidad','Recomendaciones de estilo de vida',
 'Alta con signos de alarma explicados','Reevaluacion en 3 meses'], u) $$;

CREATE FUNCTION pg_temp.ip(c INT, u BIGINT) RETURNS INET LANGUAGE sql IMMUTABLE AS $$
SELECT ('10.' || c || '.' || (u % 250) || '.' || (10 + u % 200))::inet $$;

-- ---------------------------------------------------------------------
-- 1. Configuracion
-- ---------------------------------------------------------------------
CREATE TEMP TABLE cfg AS
SELECT DATE '2026-02-01' AS f_ini, (CURRENT_DATE + 42) AS f_fin;

CREATE TEMP TABLE cfg_clinica (id_clinica INT PRIMARY KEY, inicio DATE, factor NUMERIC, n_recep INT, n_pac INT, pref_tel TEXT);
INSERT INTO cfg_clinica VALUES
    (1, '2025-05-01', 1.00, 4, 1100, '+506 8'),
    (2, '2025-05-01', 0.85, 3,  650, '+506 8'),
    (3, '2025-05-01', 0.78, 3,  550, '+506 8'),
    (4, '2025-06-01', 0.58, 2,  300, '+506 8'),
    (5, '2025-05-01', 0.90, 3,  850, '+507 6'),
    (6, '2026-01-15', 0.80, 2,  200, '+502 5');

-- profesionales por clinica y especialidad
CREATE TEMP TABLE cfg_prof_dist (id_clinica INT, id_especialidad INT, n INT);
INSERT INTO cfg_prof_dist VALUES
    (1,1,6),(1,2,3),(1,3,2),(1,4,2),(1,5,3),(1,6,3),(1,7,3),(1,8,2),
    (2,1,4),(2,2,2),(2,3,1),(2,4,1),(2,5,2),(2,6,2),(2,7,2),(2,8,1),
    (3,1,3),(3,2,2),(3,3,2),(3,4,3),(3,5,2),(3,6,3),(3,7,3),(3,8,2),
    (4,1,3),(4,2,1),(4,4,1),(4,5,1),(4,6,2),(4,7,1),(4,8,1),
    (5,1,5),(5,2,3),(5,3,2),(5,4,2),(5,5,2),(5,6,3),(5,7,2),(5,8,2),
    (6,1,2),(6,2,1),(6,4,1),(6,5,1),(6,6,2),(6,7,1),(6,8,1);

-- especialidad: duracion (min), demanda base, servicios y tasa de notas
CREATE TEMP TABLE esp_def (id_especialidad INT PRIMARY KEY, dur INT, base NUMERIC, nombre1 TEXT, nombre2 TEXT, nota_rate NUMERIC);
INSERT INTO esp_def VALUES
    (1, 30, 0.85, 'Consulta General', 'Control',          0.92),
    (2, 30, 0.80, 'Pediatria',        'Nino Sano',        0.90),
    (3, 45, 0.70, 'Cardiologia',      'Electrocardio',    0.88),
    (4, 20, 0.65, 'Dermatologia',     'Crioterapia',      0.80),
    (5, 30, 0.72, 'Ginecologia',      'Papanicolau',      0.88),
    (6, 60, 0.78, 'Limpieza Dental',  'Endodoncia',       0.70),
    (7, 45, 0.82, 'Psicoterapia',     'Orientacion',      0.97),
    (8, 30, 0.55, 'Plan Nutricional', 'Seguimiento Nut',  0.85);

-- patrones de horario semanal (dia ISO: 1 = lunes)
CREATE TEMP TABLE pat_def (patron INT, dia INT, hi TIME, hf TIME);
INSERT INTO pat_def SELECT 1, d, t.hi, t.hf FROM generate_series(1,5) d,
    (VALUES ('08:00'::time, '12:00'::time), ('13:00'::time, '17:00'::time)) t(hi, hf);
INSERT INTO pat_def SELECT 2, d, '07:00', '15:00' FROM generate_series(1,5) d;
INSERT INTO pat_def SELECT 3, x.d, t.hi, t.hf FROM (VALUES (1),(3),(5)) x(d),
    (VALUES ('08:00'::time, '12:00'::time), ('14:00'::time, '18:00'::time)) t(hi, hf);
INSERT INTO pat_def SELECT 4, d, '12:00', '20:00' FROM generate_series(1,5) d;
INSERT INTO pat_def VALUES (4, 6, '08:00', '12:00');
INSERT INTO pat_def SELECT 5, d, '07:00', '13:00' FROM generate_series(1,6) d;

-- ---------------------------------------------------------------------
-- 2. Catalogos y clinicas
-- ---------------------------------------------------------------------
INSERT INTO especialidad (id, nombre, descripcion) OVERRIDING SYSTEM VALUE VALUES
    (1, 'Medicina General', 'Atencion primaria y control de enfermedades comunes'),
    (2, 'Pediatria',        'Atencion medica de ninos y adolescentes'),
    (3, 'Cardiologia',      'Diagnostico y tratamiento de enfermedades del corazon'),
    (4, 'Dermatologia',     'Cuidado de la piel, el cabello y las unas'),
    (5, 'Ginecologia',      'Salud reproductiva y control ginecologico'),
    (6, 'Odontologia',      'Salud dental y tratamientos bucales'),
    (7, 'Psicologia',       'Evaluacion y psicoterapia'),
    (8, 'Nutricion',        'Planes alimentarios y seguimiento nutricional');

INSERT INTO clinica (id, nombre, zona_horaria, identificador) OVERRIDING SYSTEM VALUE VALUES
    (1, 'Clinica San Jose Centro',   'America/Costa_Rica', 'cr-sanjose-centro'),
    (2, 'Clinica Heredia Norte',     'America/Costa_Rica', 'cr-heredia-norte'),
    (3, 'Centro Medico Escazu',      'America/Costa_Rica', 'cr-escazu'),
    (4, 'Clinica Cartago Sur',       'America/Costa_Rica', 'cr-cartago-sur'),
    (5, 'Clinica Ciudad de Panama',  'America/Panama',     'pa-ciudad-panama'),
    (6, 'Clinica Antigua Guatemala', 'America/Guatemala',  'gt-antigua');

-- ---------------------------------------------------------------------
-- 3. Usuarios y profesionales
-- ---------------------------------------------------------------------
CREATE TEMP TABLE u_stage AS
WITH base AS (
    SELECT 'ADMIN' AS tipo, 1 AS ord, c.id_clinica, 1 AS seq, NULL::int AS id_esp, 2 AS id_rol
    FROM cfg_clinica c
    UNION ALL
    SELECT 'RECEP', 2, c.id_clinica, g, NULL, 3
    FROM cfg_clinica c CROSS JOIN LATERAL generate_series(1, c.n_recep) g
    UNION ALL
    SELECT 'PROF', 3, d.id_clinica, g, d.id_especialidad, 4
    FROM cfg_prof_dist d CROSS JOIN LATERAL generate_series(1, d.n) g
)
SELECT row_number() OVER (ORDER BY ord, id_clinica, id_esp NULLS FIRST, seq) + 1 AS id_usuario,
       b.*, (random() < 0.5) AS es_f, random() AS r1, random() AS r2, random() AS r3
FROM base b;

CREATE TEMP TABLE prof_stage AS
SELECT row_number() OVER (ORDER BY x.id_usuario) AS id_profesional,
       x.id_clinica, x.id_usuario, x.id_esp AS id_especialidad,
       CASE WHEN x.id_clinica IN (1, 2, 3) AND x.id_esp = 1 AND x.seq IN (1, 2) THEN 1
            WHEN x.p1 < 0.40 THEN 1 WHEN x.p1 < 0.60 THEN 2 WHEN x.p1 < 0.75 THEN 3
            WHEN x.p1 < 0.90 THEN 4 ELSE 5 END                                   AS patron,
       CASE WHEN x.p2 < 0.12 THEN 0.35 + 0.15 * x.p3 ELSE 0.75 + 0.5 * x.p3 END AS factor,
       CASE WHEN x.id_clinica IN (1, 2, 3) AND x.id_esp = 1 AND x.seq IN (1, 2) THEN cc.inicio
            ELSE GREATEST(cc.inicio, CASE WHEN x.p4 < 0.08 THEN DATE '2025-05-01' + floor(x.p5 * 420)::int
                                          ELSE DATE '2025-05-01' END) END        AS f_ini,
       CASE WHEN x.id_clinica IN (1, 2, 3) AND x.id_esp = 1 AND x.seq IN (1, 2) THEN DATE '2099-12-31'
            WHEN x.p6 < 0.03 THEN DATE '2026-03-01' + floor(x.p7 * 200)::int
            ELSE DATE '2099-12-31' END                                            AS f_fin,
       CASE WHEN x.p8 < 0.10 THEN 0.45 + 0.20 * x.p9 ELSE 0.85 + 0.15 * x.p9 END AS cumpl
FROM (SELECT u.*, random() p1, random() p2, random() p3, random() p4, random() p5,
             random() p6, random() p7, random() p8, random() p9
      FROM u_stage u WHERE u.tipo = 'PROF') x
JOIN cfg_clinica cc ON cc.id_clinica = x.id_clinica;

CREATE TEMP TABLE u_final AS
SELECT u.*,
       CASE u.tipo
           WHEN 'RECEP' THEN NOT ((u.id_clinica = 1 AND u.seq = 4) OR (u.id_clinica = 5 AND u.seq = 3))
           WHEN 'PROF'  THEN p.f_fin > CURRENT_DATE
           ELSE TRUE
       END AS activo
FROM u_stage u LEFT JOIN prof_stage p ON p.id_usuario = u.id_usuario;

INSERT INTO usuario (id, id_clinica, id_rol, nombre_usuario, correo, token_sub, activo) OVERRIDING SYSTEM VALUE
SELECT 1, NULL, 1, 'Administrador Plataforma', 'plataforma@medicitas.test', '20000000-0000-0000-0000-000000000001', TRUE
UNION ALL
SELECT u.id_usuario, u.id_clinica, u.id_rol,
       CASE WHEN u.tipo = 'PROF' THEN CASE WHEN u.es_f THEN 'Dra. ' ELSE 'Dr. ' END ELSE '' END
       || CASE WHEN u.es_f THEN pg_temp.nom_f(u.r1) ELSE pg_temp.nom_m(u.r1) END
       || ' ' || pg_temp.ape(u.r2) || ' ' || pg_temp.ape(u.r3),
       'u' || u.id_usuario || '@mc' || u.id_clinica || '.test',
       CASE
           WHEN u.id_clinica IN (1, 2, 3) AND u.tipo = 'ADMIN' AND u.seq = 1
               THEN '20000000-0000-0000-0000-000000000' || u.id_clinica || '01'
           WHEN u.id_clinica IN (1, 2, 3) AND u.tipo = 'RECEP' AND u.seq = 1
               THEN '20000000-0000-0000-0000-000000000' || u.id_clinica || '02'
           WHEN u.id_clinica IN (1, 2, 3) AND u.tipo = 'PROF' AND u.id_esp = 1 AND u.seq = 1
               THEN '20000000-0000-0000-0000-000000000' || u.id_clinica || '03'
           WHEN u.id_clinica IN (1, 2, 3) AND u.tipo = 'PROF' AND u.id_esp = 1 AND u.seq = 2
               THEN '20000000-0000-0000-0000-000000000' || u.id_clinica || '04'
           ELSE 'seed-sub-' || lpad(u.id_usuario::text, 5, '0')
       END,
       u.activo
FROM u_final u;

CREATE TEMP TABLE adm AS SELECT id_clinica, id_usuario FROM u_final WHERE tipo = 'ADMIN';
CREATE TEMP TABLE recep_arr AS
SELECT id_clinica, array_agg(id_usuario ORDER BY id_usuario) AS arr
FROM u_final WHERE tipo = 'RECEP' AND activo GROUP BY id_clinica;

-- servicios (2 por especialidad y clinica) y habilitacion de profesionales
CREATE TEMP TABLE serv_stage AS
SELECT row_number() OVER (ORDER BY d.id_clinica, d.id_especialidad, g) AS id_servicio,
       d.id_clinica, d.id_especialidad, g AS idx,
       CASE g WHEN 1 THEN e.nombre1 ELSE e.nombre2 END AS nombre, e.dur
FROM cfg_prof_dist d
JOIN esp_def e ON e.id_especialidad = d.id_especialidad
CROSS JOIN LATERAL generate_series(1, 2) g;

INSERT INTO servicio (id, id_clinica, id_especialidad, nombre, duracion_min) OVERRIDING SYSTEM VALUE
SELECT id_servicio, id_clinica, id_especialidad, nombre, dur FROM serv_stage;

CREATE TEMP TABLE serv_pair AS
SELECT id_clinica, id_especialidad, min(id_servicio) AS s1, max(id_servicio) AS s2
FROM serv_stage GROUP BY id_clinica, id_especialidad;

INSERT INTO profesional (id, id_clinica, id_usuario, id_especialidad) OVERRIDING SYSTEM VALUE
SELECT id_profesional, id_clinica, id_usuario, id_especialidad FROM prof_stage;

INSERT INTO profesional_x_servicio (id, id_clinica, id_profesional, id_servicio) OVERRIDING SYSTEM VALUE
SELECT row_number() OVER (ORDER BY p.id_profesional, s.id_servicio), p.id_clinica, p.id_profesional, s.id_servicio
FROM prof_stage p
JOIN serv_stage s ON s.id_clinica = p.id_clinica AND s.id_especialidad = p.id_especialidad;

INSERT INTO horario_atencion (id, id_clinica, id_profesional, dia, hora_inicio, hora_fin) OVERRIDING SYSTEM VALUE
SELECT row_number() OVER (ORDER BY p.id_profesional, h.dia, h.hi), p.id_clinica, p.id_profesional, h.dia, h.hi, h.hf
FROM prof_stage p JOIN pat_def h ON h.patron = p.patron;

-- ---------------------------------------------------------------------
-- 4. Bloqueos de agenda (vacaciones, permisos, cierres) - antes de generar los espacios
-- ---------------------------------------------------------------------
CREATE TEMP TABLE bloq_raw AS
SELECT p.id_profesional, p.id_clinica, 'vacaciones'::motivo_bloqueo AS motivo, NULL::int AS id_servicio,
       (DATE '2025-07-01' + floor(random() * 500)::int) AS d_ini, (5 + floor(random() * 10))::int AS dias, FALSE AS parcial
FROM prof_stage p WHERE random() < 0.85
UNION ALL
SELECT p.id_profesional, p.id_clinica, 'vacaciones'::motivo_bloqueo, NULL::int, DATE '2025-12-22', 12, FALSE
FROM prof_stage p WHERE random() < 0.25
UNION ALL
SELECT p.id_profesional, p.id_clinica, 'permisos'::motivo_bloqueo, NULL::int,
       (DATE '2025-06-01' + floor(random() * 520)::int), (1 + floor(random() * 2))::int, (random() < 0.5)
FROM prof_stage p CROSS JOIN generate_series(1, 3) g WHERE random() < 0.55
UNION ALL
-- permisos proximos, registrados despues de reservar: dejan citas en conflicto (RF6)
SELECT p.id_profesional, p.id_clinica, 'permisos'::motivo_bloqueo, NULL::int,
       (CURRENT_DATE + 4 + floor(random() * 22)::int), (1 + floor(random() * 3))::int, FALSE
FROM prof_stage p WHERE random() < 0.15
UNION ALL
-- bloqueo de un servicio puntual: solo cuando el profesional es el unico de la clinica que lo brinda
SELECT p.id_profesional, p.id_clinica, 'permisos'::motivo_bloqueo, sp.s2,
       (DATE '2026-02-09' + floor(random() * 200)::int), 2, FALSE
FROM prof_stage p
JOIN serv_pair sp ON sp.id_clinica = p.id_clinica AND sp.id_especialidad = p.id_especialidad
WHERE (SELECT count(*) FROM prof_stage q
       WHERE q.id_clinica = p.id_clinica AND q.id_especialidad = p.id_especialidad) = 1
  AND random() < 0.8;

CREATE TEMP TABLE bloq_stage AS
SELECT row_number() OVER (ORDER BY r.id_profesional, r.d_ini) AS id_bloqueo,
       r.id_clinica, r.id_profesional, r.id_servicio, a.id_usuario, r.motivo,
       CASE WHEN r.parcial THEN (r.d_ini + TIME '13:00') AT TIME ZONE cl.zona_horaria
            ELSE r.d_ini::timestamp AT TIME ZONE cl.zona_horaria END AS inicio,
       CASE WHEN r.parcial THEN (r.d_ini + TIME '17:00') AT TIME ZONE cl.zona_horaria
            ELSE ((r.d_ini + r.dias)::timestamp AT TIME ZONE cl.zona_horaria) - INTERVAL '1 second' END AS fin
FROM bloq_raw r
JOIN prof_stage p ON p.id_profesional = r.id_profesional
JOIN cfg_clinica cc ON cc.id_clinica = r.id_clinica
JOIN clinica cl ON cl.id = r.id_clinica
JOIN adm a ON a.id_clinica = r.id_clinica
CROSS JOIN cfg
WHERE r.d_ini BETWEEN GREATEST(cfg.f_ini, cc.inicio, p.f_ini) AND LEAST(p.f_fin, cfg.f_fin)
  AND NOT (r.id_profesional IN (1, 2) AND r.d_ini >= CURRENT_DATE);

INSERT INTO bloqueo_agenda (id, id_clinica, id_profesional, id_servicio, id_usuario, hora_inicio, hora_fin, motivo) OVERRIDING SYSTEM VALUE
SELECT id_bloqueo, id_clinica, id_profesional, id_servicio, id_usuario, inicio, fin, motivo FROM bloq_stage;

-- ---------------------------------------------------------------------
-- 5. Pacientes
-- ---------------------------------------------------------------------
CREATE TEMP TABLE pac_stage AS
SELECT row_number() OVER (ORDER BY q.id_clinica, q.n) AS id_paciente, q.*
FROM (
    SELECT cc.id_clinica, g AS n, cc.pref_tel,
           CASE WHEN u1 < 0.18 THEN 'N' WHEN u1 < 0.55 THEN 'J' ELSE 'M' END AS grupo,
           u2, u3, u4, u5, u6, u7, u8
    FROM cfg_clinica cc
    CROSS JOIN LATERAL generate_series(1, cc.n_pac) g
    CROSS JOIN LATERAL (SELECT random() u1, random() u2, random() u3, random() u4,
                               random() u5, random() u6, random() u7, random() u8) r
) q;

INSERT INTO paciente (id, id_clinica, identificacion, nombre, fecha_nacimiento, telefono, correo) OVERRIDING SYSTEM VALUE
SELECT p.id_paciente, p.id_clinica,
       '1-' || lpad((((p.n::bigint * 7919) % 900000000) + 100000000)::text, 9, '0'),
       left(CASE WHEN p.u2 < 0.5 THEN pg_temp.nom_f(p.u3) ELSE pg_temp.nom_m(p.u3) END
            || ' ' || pg_temp.ape(p.u4) || ' ' || pg_temp.ape(p.u5), 32),
       CURRENT_DATE - (CASE p.grupo
            WHEN 'N' THEN 365.25 * (1 + 14 * p.u6)
            WHEN 'J' THEN 365.25 * (15 + 25 * p.u6)
            ELSE 365.25 * (40 + 48 * power(p.u6, 1.4)) END)::int,
       CASE WHEN p.u7 < 0.88 THEN p.pref_tel || lpad(floor(p.u8 * 10000000)::int::text, 7, '0') END,
       CASE WHEN p.u7 > 0.28 THEN 'p' || p.id_paciente || '@mail.test' END
FROM pac_stage p;

-- grupos con propension a ausentarse (riesgo) y orden de frecuencia (rn bajo = paciente frecuente)
CREATE TEMP TABLE pac_pool AS
SELECT id_clinica, grupo, id_paciente,
       row_number() OVER (PARTITION BY id_clinica, grupo ORDER BY id_paciente) AS rn,
       0.03 + 0.30 * power(random(), 3) AS riesgo
FROM pac_stage;
CREATE TEMP TABLE pool_size AS SELECT id_clinica, grupo, count(*)::int AS n FROM pac_pool GROUP BY id_clinica, grupo;
CREATE INDEX ON pac_pool (id_clinica, grupo, rn);

-- ---------------------------------------------------------------------
-- 6. Espacios de agenda (slots) y ocupacion
-- ---------------------------------------------------------------------
CREATE TEMP TABLE slot AS
SELECT row_number() OVER ()                                              AS slot_id,
       p.id_clinica, p.id_profesional, p.id_especialidad,
       (s.t AT TIME ZONE cl.zona_horaria)                                AS inicio,
       (s.t AT TIME ZONE cl.zona_horaria) + make_interval(mins => e.dur) AS fin,
       d.dia::date                                                       AS dia,
       EXTRACT(HOUR FROM s.t)::int                                       AS hora,
       h.dia                                                             AS dow,
       p.factor                                                          AS f_prof,
       GREATEST(cc.inicio, p.f_ini)                                      AS f_arranque,
       CASE WHEN random() < 0.65 THEN sp.s1 ELSE sp.s2 END               AS id_servicio,
       random() AS u_occ, random() AS u_chain, random() AS u_est, random() AS u_lead,
       random() AS u_lead2, random() AS u_grp, random() AS u_pac
FROM prof_stage p
JOIN cfg_clinica cc ON cc.id_clinica = p.id_clinica
JOIN clinica cl ON cl.id = p.id_clinica
JOIN esp_def e ON e.id_especialidad = p.id_especialidad
JOIN serv_pair sp ON sp.id_clinica = p.id_clinica AND sp.id_especialidad = p.id_especialidad
CROSS JOIN cfg
CROSS JOIN LATERAL generate_series(GREATEST(cfg.f_ini, cc.inicio, p.f_ini)::timestamp,
                                   LEAST(p.f_fin, cfg.f_fin)::timestamp, INTERVAL '1 day') AS d(dia)
JOIN pat_def h ON h.patron = p.patron AND h.dia = EXTRACT(ISODOW FROM d.dia)::int
CROSS JOIN LATERAL generate_series(d.dia + h.hi, d.dia + h.hf - make_interval(mins => e.dur),
                                   make_interval(mins => e.dur)) AS s(t)
WHERE to_char(d.dia, 'MM-DD') NOT IN ('01-01', '05-01', '07-25', '08-15', '09-15', '12-25')   -- feriados
  AND d.dia::date NOT IN (DATE '2026-04-02', DATE '2026-04-03');                              -- Semana Santa
CREATE INDEX ON slot (id_profesional, inicio);

-- los bloqueos retiran la disponibilidad (los futuros dejan ~50% de espacios: conflictos RF6)
DELETE FROM slot s USING bloq_stage b
WHERE b.id_profesional = s.id_profesional
  AND (b.id_servicio IS NULL OR b.id_servicio = s.id_servicio)
  AND s.inicio < b.fin AND s.fin > b.inicio
  AND (s.fin <= now() OR random() < 0.5);
ANALYZE slot;

-- probabilidad de ocupacion de cada espacio
CREATE TEMP TABLE slot_occ AS
SELECT x.*, (x.u_occ < x.p_occ AND NOT (x.id_profesional IN (1, 2) AND x.dia >= CURRENT_DATE + 10)) AS occ, FALSE AS es_origen, NULL::bigint AS origen_slot
FROM (
    SELECT s.*,
        LEAST(0.97,
            e.base * cc.factor * s.f_prof
            * CASE s.dow WHEN 1 THEN 1.10 WHEN 2 THEN 1.05 WHEN 3 THEN 1.00 WHEN 4 THEN 0.98 WHEN 5 THEN 0.88 ELSE 0.70 END
            * CASE s.hora WHEN 7 THEN 0.85 WHEN 8 THEN 1.00 WHEN 9 THEN 1.15 WHEN 10 THEN 1.15 WHEN 11 THEN 1.00
                          WHEN 12 THEN 0.70 WHEN 13 THEN 0.75 WHEN 14 THEN 1.05 WHEN 15 THEN 1.10 WHEN 16 THEN 1.00
                          WHEN 17 THEN 0.85 WHEN 18 THEN 0.75 ELSE 0.60 END
            * CASE EXTRACT(MONTH FROM s.dia)::int WHEN 1 THEN 0.85 WHEN 3 THEN 1.05 WHEN 4 THEN 0.95 WHEN 7 THEN 0.90
                          WHEN 10 THEN 1.05 WHEN 11 THEN 1.05 WHEN 12 THEN 0.80 ELSE 1.00 END
            * LEAST(1.15, 0.80 + 0.012 * ((s.dia - DATE '2025-05-01') / 30.4))                -- tendencia de crecimiento
            * LEAST(1.0, 0.30 + (s.dia - s.f_arranque) / 110.0)                               -- rampa (clinica o profesional nuevo)
            * CASE WHEN s.fin <= now() THEN 1.0
                   ELSE GREATEST(0.04, exp(-(EXTRACT(EPOCH FROM s.inicio - now()) / 86400.0) / 12.0)) END   -- horizonte de reserva
            * CASE WHEN s.id_clinica = 2 AND s.dia >= DATE '2026-08-01' AND s.dia < DATE '2026-09-01' THEN 0.62
                   WHEN s.id_clinica = 5 AND s.dia >= DATE '2026-03-01' AND s.dia < DATE '2026-05-01' THEN 1.25
                   ELSE 1.0 END
            * CASE WHEN s.id_clinica = 3 AND s.id_especialidad = 4 THEN 1.45
                   WHEN s.id_clinica = 1 AND s.id_especialidad = 3 THEN 1.35
                   WHEN s.id_especialidad = 2 AND EXTRACT(MONTH FROM s.dia)::int IN (6, 7, 8) THEN 1.20
                   ELSE 1.0 END
        ) AS p_occ
    FROM slot s
    JOIN esp_def e ON e.id_especialidad = s.id_especialidad
    JOIN cfg_clinica cc ON cc.id_clinica = s.id_clinica
) x;
CREATE INDEX ON slot_occ (id_profesional, inicio);

-- reprogramaciones: origen (reprogramada) -> sucesora una semana despues, mismo profesional y hora
UPDATE slot_occ o SET es_origen = TRUE
WHERE o.occ AND o.u_chain < 0.065
  AND EXISTS (SELECT 1 FROM slot_occ t
              WHERE t.id_profesional = o.id_profesional
                AND t.inicio = o.inicio + INTERVAL '7 days' AND NOT t.occ);
UPDATE slot_occ t SET occ = TRUE, origen_slot = o.slot_id
FROM slot_occ o
WHERE o.es_origen AND t.id_profesional = o.id_profesional
  AND t.inicio = o.inicio + INTERVAL '7 days' AND NOT t.occ;

-- ---------------------------------------------------------------------
-- 7. Citas: paciente, servicio, anticipacion y estado
-- ---------------------------------------------------------------------
CREATE TEMP TABLE c_base AS
SELECT s.slot_id, s.id_clinica, s.id_profesional, s.id_especialidad, s.id_servicio, s.inicio, s.fin,
       s.dia, s.hora, s.dow, s.u_est, s.u_lead, s.u_lead2, s.es_origen, s.origen_slot,
       pp.id_paciente, pp.riesgo
FROM slot_occ s
JOIN pool_size ps ON ps.id_clinica = s.id_clinica AND ps.grupo = pg_temp.grupo(s.id_especialidad, s.u_grp)
JOIN pac_pool pp ON pp.id_clinica = ps.id_clinica AND pp.grupo = ps.grupo
                AND pp.rn = 1 + floor(ps.n * power(s.u_pac, 1.8))::int
WHERE s.occ AND s.origen_slot IS NULL;

-- la sucesora conserva paciente y servicio del origen
INSERT INTO c_base
SELECT t.slot_id, t.id_clinica, t.id_profesional, t.id_especialidad, o.id_servicio, t.inicio, t.fin,
       t.dia, t.hora, t.dow, t.u_est, t.u_lead, t.u_lead2, FALSE, t.origen_slot,
       o.id_paciente, o.riesgo
FROM slot_occ t
JOIN c_base o ON o.slot_id = t.origen_slot AND o.es_origen
WHERE t.origen_slot IS NOT NULL;

CREATE TEMP TABLE c_est AS
SELECT m.*,
       CASE
           WHEN m.es_origen THEN 'reprogramada'
           WHEN m.fin > now() THEN CASE WHEN m.u_est < 0.07 THEN 'cancelada' ELSE 'reservada' END
           WHEN m.u_est < m.p_cancel THEN 'cancelada'
           WHEN m.u_est < m.p_cancel + m.p_aus THEN 'ausente'
           ELSE 'atendida'
       END AS estado
FROM (
    SELECT l.*,
           LEAST(0.35, 0.07 + 0.006 * l.lead_days)
             * CASE WHEN l.id_clinica = 4 THEN 1.35 ELSE 1.0 END
             + CASE WHEN l.id_clinica = 2 AND l.dia >= DATE '2026-08-01' AND l.dia < DATE '2026-09-01' THEN 0.12 ELSE 0 END AS p_cancel,
           LEAST(0.60, l.riesgo
             + CASE WHEN l.dow = 1 THEN 0.02 ELSE 0 END
             + CASE WHEN l.hora <= 8 THEN 0.02 ELSE 0 END
             + CASE WHEN l.id_especialidad = 7 THEN 0.03 WHEN l.id_especialidad = 6 THEN -0.02 ELSE 0 END
             + CASE WHEN l.lead_days > 14 THEN 0.04 ELSE 0 END) AS p_aus
    FROM (
        SELECT b.*, cc.inicio AS inicio_op, cl.zona_horaria AS zona,
               CASE WHEN b.u_lead2 < 0.20 THEN 0 ELSE floor(-ln(1 - b.u_lead) * 7)::int END AS lead_days
        FROM c_base b
        JOIN cfg_clinica cc ON cc.id_clinica = b.id_clinica
        JOIN clinica cl ON cl.id = b.id_clinica
    ) l
) m;

-- fecha de creacion de la cita: en horario laboral local (7-19 h), nunca posterior a ahora
-- ni a una hora antes del inicio; las citas futuras se reservaron en los ultimos 10 dias
ALTER TABLE c_est ADD COLUMN creada TIMESTAMPTZ;
UPDATE c_est SET creada = GREATEST(
    LEAST(
        CASE WHEN fin > now() THEN
                  (date_trunc('day', (now() - floor(u_lead * 10) * INTERVAL '1 day') AT TIME ZONE zona)
                   + (7 + 12 * u_lead2) * INTERVAL '1 hour') AT TIME ZONE zona
             WHEN lead_days = 0 THEN inicio - (1 + 3 * u_lead2) * INTERVAL '1 hour'
             ELSE (date_trunc('day', (inicio - lead_days * INTERVAL '1 day') AT TIME ZONE zona)
                   + (7 + 12 * u_lead2) * INTERVAL '1 hour') AT TIME ZONE zona END,
        inicio - INTERVAL '1 hour',
        now() - INTERVAL '5 minutes'),
    inicio_op::timestamptz);
CREATE INDEX ON c_est (slot_id);
-- la sucesora se crea despues que su origen
UPDATE c_est t SET creada = LEAST(GREATEST(t.creada, o.creada + INTERVAL '1 hour'), now() - INTERVAL '1 minute')
FROM c_est o WHERE t.origen_slot = o.slot_id;

-- una persona no puede tener dos citas vigentes solapadas (I2): se cancela la que choca
WITH choque AS (
    SELECT slot_id FROM (
        SELECT slot_id, inicio,
               max(fin) OVER (PARTITION BY id_paciente ORDER BY inicio, slot_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS fin_previo
        FROM c_est WHERE estado IN ('reservada', 'atendida')
    ) z WHERE inicio < fin_previo
)
UPDATE c_est e SET estado = 'cancelada' FROM choque c WHERE c.slot_id = e.slot_id;

-- dejar las 10 citas pasadas mas recientes del profesional 1 (clinica 1) en estado 'reservada' para pruebas de RF12 y RF15
UPDATE c_est SET estado = 'reservada'
WHERE slot_id IN (
    SELECT slot_id FROM c_est
    WHERE id_clinica = 1 AND id_profesional = 1 AND fin <= now() AND NOT es_origen AND estado = 'atendida'
    ORDER BY inicio DESC LIMIT 10
);

CREATE TEMP TABLE cita_final AS
SELECT row_number() OVER (ORDER BY slot_id) AS id, c.* FROM c_est c;
CREATE INDEX ON cita_final (slot_id);

INSERT INTO cita (id, id_clinica, id_cita_origen, id_paciente, id_profesional, id_servicio,
                  id_usuario_cancelo, creada, estado, hora_inicio, hora_fin, motivo_cancelada) OVERRIDING SYSTEM VALUE
SELECT f.id, f.id_clinica, o.id, f.id_paciente, f.id_profesional, f.id_servicio,
       CASE WHEN f.estado = 'cancelada' THEN r.arr[1 + floor(random() * cardinality(r.arr))::int] END,
       f.creada, f.estado::estado_cita, f.inicio, f.fin,
       CASE WHEN f.estado = 'cancelada' THEN
            CASE WHEN f.id_clinica = 2 AND f.dia >= DATE '2026-08-01' AND f.dia < DATE '2026-09-01' AND random() < 0.60
                 THEN 'Profesional no disponible'
                 ELSE pg_temp.pick(ARRAY['Paciente avisa con anticipacion', 'Paciente avisa con anticipacion',
                      'Paciente avisa con anticipacion', 'Enfermedad del paciente', 'Enfermedad del paciente',
                      'Sin transporte', 'Conflicto laboral', 'Conflicto laboral', 'Cambio de planes',
                      'Profesional no disponible', 'Solicitud de la clinica'], random()) END
       END
FROM cita_final f
LEFT JOIN cita_final o ON o.slot_id = f.origen_slot
JOIN recep_arr r ON r.id_clinica = f.id_clinica;

-- ---------------------------------------------------------------------
-- 8. Notas clinicas (solo citas atendidas; cumplimiento distinto por profesional)
-- ---------------------------------------------------------------------
INSERT INTO nota_clinica (id, id_clinica, id_cita, id_profesional, contenido, fecha_creacion) OVERRIDING SYSTEM VALUE
SELECT row_number() OVER (ORDER BY q.id_cita), q.id_clinica, q.id_cita, q.id_profesional, q.contenido, q.fecha
FROM (
    SELECT c.id_clinica, c.id AS id_cita, c.id_profesional, p.id_especialidad, p.cumpl, e.nota_rate,
           random() AS u_nota,
           'Motivo: ' || pg_temp.motivo(p.id_especialidad, random())
           || '. Hallazgos: ' || pg_temp.hallazgo(random())
           || '. Plan: ' || pg_temp.plan(random()) || '.' AS contenido,
           GREATEST(c.hora_fin, LEAST(c.hora_fin +
               CASE WHEN random() < 0.08 + (1 - p.cumpl) * 0.60
                    THEN (1 + floor(random() * 6)) * INTERVAL '1 day' + random() * INTERVAL '8 hours'
                    ELSE (10 + floor(random() * 230)) * INTERVAL '1 minute' END, now())) AS fecha
    FROM cita c
    JOIN prof_stage p ON p.id_profesional = c.id_profesional
    JOIN esp_def e ON e.id_especialidad = p.id_especialidad
    WHERE c.estado = 'atendida'
) q
WHERE q.u_nota < q.cumpl * q.nota_rate;

-- ---------------------------------------------------------------------
-- 9. Auditoria (RF18): escrituras/lecturas de contacto y de notas + 3 anomalias
-- ---------------------------------------------------------------------
CREATE TEMP TABLE aud_stage AS
-- (a) alta de pacientes por recepcion (datos de contacto)
SELECT p.id_clinica, r.arr[1 + floor(random() * cardinality(r.arr))::int] AS id_usuario, p.id_paciente,
       NULL::int AS id_nota, 'escritura' AS accion, 'telefono,correo' AS info,
       COALESCE(fc.min_creada - INTERVAL '3 minutes',
                cc.inicio::timestamptz + random() * (now() - cc.inicio::timestamptz)) AS estampa,
       NULL::inet AS ip_x
FROM pac_stage p
JOIN cfg_clinica cc ON cc.id_clinica = p.id_clinica
JOIN recep_arr r ON r.id_clinica = p.id_clinica
LEFT JOIN (SELECT id_paciente, min(creada) AS min_creada FROM cita GROUP BY id_paciente) fc
       ON fc.id_paciente = p.id_paciente
UNION ALL
-- (b) actualizacion de telefono (3% de los pacientes)
SELECT p.id_clinica, r.arr[1 + floor(random() * cardinality(r.arr))::int], p.id_paciente,
       NULL, 'escritura', 'telefono',
       now() - random() * INTERVAL '300 days' - INTERVAL '1 hour', NULL
FROM pac_stage p JOIN recep_arr r ON r.id_clinica = p.id_clinica
WHERE random() < 0.03
UNION ALL
-- (c) lectura de contacto al reservar (55% de las citas)
SELECT c.id_clinica, r.arr[1 + floor(random() * cardinality(r.arr))::int], c.id_paciente,
       NULL, 'lectura', 'telefono,correo', c.creada + INTERVAL '2 minutes', NULL
FROM cita c JOIN recep_arr r ON r.id_clinica = c.id_clinica
WHERE random() < 0.55
UNION ALL
-- (d) escritura de la nota por el profesional
SELECT n.id_clinica, p.id_usuario, c.id_paciente, n.id, 'escritura', 'contenido', n.fecha_creacion, NULL
FROM nota_clinica n
JOIN cita c ON c.id_clinica = n.id_clinica AND c.id = n.id_cita
JOIN prof_stage p ON p.id_profesional = n.id_profesional
UNION ALL
-- (e) el profesional lee su nota previa del mismo paciente antes de la cita
SELECT z.id_clinica, p.id_usuario, z.id_paciente, z.prev_nota, 'lectura', 'contenido',
       z.hora_inicio - INTERVAL '10 minutes', NULL
FROM (
    SELECT n.id_clinica, c.id_paciente, c.id_profesional, c.hora_inicio,
           lag(n.id) OVER (PARTITION BY c.id_paciente, c.id_profesional ORDER BY c.hora_inicio) AS prev_nota
    FROM nota_clinica n JOIN cita c ON c.id_clinica = n.id_clinica AND c.id = n.id_cita
) z
JOIN prof_stage p ON p.id_profesional = z.id_profesional
WHERE z.prev_nota IS NOT NULL AND random() < 0.30
UNION ALL
-- ANOMALIA A: recepcionista de la clinica 3 lee contactos de madrugada (sep-oct 2026)
SELECT 3, (SELECT id_usuario FROM u_final WHERE tipo = 'RECEP' AND id_clinica = 3 AND seq = 1),
       pa.id_paciente, NULL, 'lectura', 'telefono,correo',
       (DATE '2026-09-01' + floor(random() * 58)::int + (1 + floor(random() * 3)) * INTERVAL '1 hour'
        + random() * INTERVAL '50 minutes') AT TIME ZONE 'America/Costa_Rica', NULL
FROM (SELECT id_paciente FROM pac_stage WHERE id_clinica = 3 ORDER BY random() LIMIT 240) pa
UNION ALL
-- ANOMALIA B: el primer profesional de la clinica 1 lee notas de colegas (oct 2026)
SELECT 1, (SELECT id_usuario FROM u_final WHERE tipo = 'PROF' AND id_clinica = 1 ORDER BY id_usuario LIMIT 1),
       nn.id_paciente, nn.id, 'lectura', 'contenido',
       ((DATE '2026-10-01' + floor(random() * 26)::int) + (8 + floor(random() * 9)) * INTERVAL '1 hour')
           AT TIME ZONE 'America/Costa_Rica', NULL
FROM (SELECT n.id, c.id_paciente FROM nota_clinica n
      JOIN cita c ON c.id_clinica = n.id_clinica AND c.id = n.id_cita
      JOIN prof_stage p ON p.id_profesional = n.id_profesional
      WHERE n.id_clinica = 1
        AND p.id_usuario <> (SELECT id_usuario FROM u_final WHERE tipo = 'PROF' AND id_clinica = 1 ORDER BY id_usuario LIMIT 1)
        AND n.fecha_creacion < DATE '2026-10-01'
      ORDER BY random() LIMIT 120) nn
UNION ALL
-- ANOMALIA C: acceso masivo desde IP externa, clinica 5, 2026-09-18 14:00-15:00 (local)
SELECT 5, (SELECT id_usuario FROM u_final WHERE tipo = 'RECEP' AND id_clinica = 5 AND seq = 1),
       pb.id_paciente, NULL, 'lectura', 'telefono,correo',
       (TIMESTAMP '2026-09-18 14:00:00' + pb.i * INTERVAL '8 seconds') AT TIME ZONE 'America/Panama',
       INET '203.0.113.50'
FROM (SELECT id_paciente, row_number() OVER (ORDER BY random()) AS i
      FROM pac_stage WHERE id_clinica = 5 LIMIT 450) pb;

INSERT INTO registro_auditoria (id_clinica, id, id_usuario, id_paciente, id_nota_clinica, accion, info_usada, estampa_de_tiempo, ip)
    OVERRIDING SYSTEM VALUE
SELECT a.id_clinica, row_number() OVER (ORDER BY a.estampa, a.id_usuario, a.id_paciente),
       a.id_usuario, a.id_paciente, a.id_nota, a.accion::accion_auditoria, a.info, a.estampa,
       COALESCE(a.ip_x, pg_temp.ip(a.id_clinica, a.id_usuario))
FROM aud_stage a;

-- ---------------------------------------------------------------------
-- 10. Errores de procedimientos (db_error), con un incidente el 2026-08-12
-- ---------------------------------------------------------------------
CREATE TEMP TABLE err_tpl (id INT, sp TEXT, estado TEXT, num INT, linea INT, proc TEXT, msg TEXT);
INSERT INTO err_tpl VALUES
    (1,  'SP_ReservarCita',            '23P01', 409, 38,  'fn_cita_before_insert', 'conflicting key value violates exclusion constraint "ex_cita_profesional_sin_solape"'),
    (2,  'SP_ReservarCita',            '23514', 422, 62,  'fn_cita_before_insert', 'La cita queda fuera del horario de atencion del profesional'),
    (3,  'SP_ReservarCita',            '23514', 422, 71,  'fn_cita_before_insert', 'El espacio solicitado esta bloqueado en la agenda del profesional'),
    (4,  'SP_CancelarCita',            '23514', 422, 28,  'fn_cita_before_update', 'La cita esta en estado final y no admite cambios'),
    (5,  'SP_ReservarCita',            '23P01', 409, 38,  'fn_cita_before_insert', 'conflicting key value violates exclusion constraint "ex_cita_paciente_sin_solape"'),
    (6,  'SP_CrearPaciente',           '23505', 409, 14,  'sp_crearpaciente',      'duplicate key value violates unique constraint "uq_paciente_identificacion"'),
    (7,  'SP_ReprogramarCita',         '23P01', 409, 31,  'sp_reprogramarcita',    'conflicting key value violates exclusion constraint "ex_cita_profesional_sin_solape"'),
    (8,  'SP_RegistrarDesenlaceCita',  '23514', 422, 45,  'fn_cita_before_update', 'No se puede registrar el desenlace antes de la hora de inicio'),
    (9,  'SP_ReservarCita',            '23514', 422, 22,  'fn_cita_before_insert', 'No se puede reservar una cita en el pasado'),
    (10, 'SP_CrearNotaClinica',        '23514', 422, 17,  'fn_nota_before_insert', 'La nota clinica solo se adjunta a citas atendidas'),
    (11, 'SP_RegistrarBloqueoAgenda',  '23514', 422, 12,  'fn_bloqueo_servicio_unico', 'El servicio solo se bloquea si el profesional es el unico habilitado para atenderlo'),
    (12, 'SP_ReservarCita',            '40P01', 409, 38,  'sp_reservarcita',       'deadlock detected'),
    (13, 'SP_ReservarCita',            '57014', 500, 38,  'sp_reservarcita',       'canceling statement due to statement timeout');

INSERT INTO db_error (user_name, error_number, error_state, error_severity, error_line, error_procedure, error_message, error_datetime)
SELECT u.nombre_usuario, t.num, t.estado, 'ERROR', t.linea, t.proc, t.msg, e.ts
FROM (
    SELECT x.tpl, x.ts, x.arr_u[1 + floor(random() * cardinality(x.arr_u))::int] AS id_u
    FROM (
        SELECT (SELECT array_agg(id_usuario) FROM u_final WHERE tipo = 'RECEP') AS arr_u,
               1 + floor(power(random(), 1.6) * 11)::int AS tpl,           -- los primeros errores son los mas frecuentes
               (DATE '2025-05-01')::timestamptz + random() * (now() - DATE '2025-05-01'::timestamptz) AS ts
        FROM generate_series(1, 3600)
    ) x
) e
JOIN err_tpl t ON t.id = e.tpl
JOIN usuario u ON u.id = e.id_u;

-- incidente: 2026-08-12 14:00-16:00 (hora de Costa Rica)
INSERT INTO db_error (user_name, error_number, error_state, error_severity, error_line, error_procedure, error_message, error_datetime)
SELECT u.nombre_usuario, t.num, t.estado, 'ERROR', t.linea, t.proc, t.msg,
       TIMESTAMPTZ '2026-08-12 20:00+00' + random() * INTERVAL '2 hours'
FROM generate_series(1, 650) g
JOIN err_tpl t ON t.id = 12 + (g % 2)
JOIN usuario u ON u.id = (SELECT id_usuario FROM u_final WHERE tipo = 'RECEP' AND id_clinica = 1 AND seq = 1 + (g % 3));

-- ---------------------------------------------------------------------
-- 11. Cierre: secuencias, triggers, validaciones
-- ---------------------------------------------------------------------
SELECT setval(pg_get_serial_sequence('clinica', 'id'),                 (SELECT max(id) FROM clinica));
SELECT setval(pg_get_serial_sequence('especialidad', 'id'),            (SELECT max(id) FROM especialidad));
SELECT setval(pg_get_serial_sequence('usuario', 'id'),                 (SELECT max(id) FROM usuario));
SELECT setval(pg_get_serial_sequence('servicio', 'id'),                (SELECT max(id) FROM servicio));
SELECT setval(pg_get_serial_sequence('profesional', 'id'),             (SELECT max(id) FROM profesional));
SELECT setval(pg_get_serial_sequence('profesional_x_servicio', 'id'), (SELECT max(id) FROM profesional_x_servicio));
SELECT setval(pg_get_serial_sequence('horario_atencion', 'id'),        (SELECT max(id) FROM horario_atencion));
SELECT setval(pg_get_serial_sequence('bloqueo_agenda', 'id'),          (SELECT max(id) FROM bloqueo_agenda));
SELECT setval(pg_get_serial_sequence('paciente', 'id'),                (SELECT max(id) FROM paciente));
SELECT setval(pg_get_serial_sequence('cita', 'id'),                    (SELECT max(id) FROM cita));
SELECT setval(pg_get_serial_sequence('nota_clinica', 'id'),            (SELECT max(id) FROM nota_clinica));
SELECT setval(pg_get_serial_sequence('registro_auditoria', 'id'),      (SELECT max(id) FROM registro_auditoria));

ALTER TABLE cita ENABLE TRIGGER trg_cita_before_insert;

DO $$
DECLARE
    v INT;
BEGIN
    SELECT count(*) INTO v FROM cita c
    WHERE c.estado = 'reprogramada'
      AND NOT EXISTS (SELECT 1 FROM cita s WHERE s.id_clinica = c.id_clinica AND s.id_cita_origen = c.id);
    IF v > 0 THEN RAISE EXCEPTION 'Citas reprogramadas sin sucesora: %', v; END IF;

    SELECT count(*) INTO v FROM cita c
    JOIN clinica cl ON cl.id = c.id_clinica
    WHERE NOT EXISTS (
        SELECT 1 FROM horario_atencion h
        WHERE h.id_clinica = c.id_clinica AND h.id_profesional = c.id_profesional
          AND h.dia = EXTRACT(ISODOW FROM c.hora_inicio AT TIME ZONE cl.zona_horaria)::int
          AND h.hora_inicio <= (c.hora_inicio AT TIME ZONE cl.zona_horaria)::time
          AND h.hora_fin    >= (c.hora_fin    AT TIME ZONE cl.zona_horaria)::time);
    IF v > 0 THEN RAISE EXCEPTION 'Citas fuera del horario de atencion: %', v; END IF;

    SELECT count(*) INTO v FROM cita c
    JOIN bloqueo_agenda b ON b.id_clinica = c.id_clinica AND b.id_profesional = c.id_profesional
     AND (b.id_servicio IS NULL OR b.id_servicio = c.id_servicio)
     AND tstzrange(c.hora_inicio, c.hora_fin) && tstzrange(b.hora_inicio, b.hora_fin)
    WHERE c.hora_fin <= now() AND c.estado IN ('reservada', 'atendida', 'ausente');
    IF v > 0 THEN RAISE EXCEPTION 'Citas pasadas dentro de un bloqueo: %', v; END IF;

    SELECT count(*) INTO v FROM cita c
    JOIN bloqueo_agenda b ON b.id_clinica = c.id_clinica AND b.id_profesional = c.id_profesional
     AND (b.id_servicio IS NULL OR b.id_servicio = c.id_servicio)
     AND tstzrange(c.hora_inicio, c.hora_fin) && tstzrange(b.hora_inicio, b.hora_fin)
    WHERE c.estado = 'reservada';
    RAISE NOTICE 'Citas reservadas en conflicto con un bloqueo (RF6): %', v;
    RAISE NOTICE 'clinicas=% usuarios=% profesionales=% pacientes=% citas=% notas=% auditoria=% errores=% bloqueos=%',
        (SELECT count(*) FROM clinica), (SELECT count(*) FROM usuario), (SELECT count(*) FROM profesional),
        (SELECT count(*) FROM paciente), (SELECT count(*) FROM cita), (SELECT count(*) FROM nota_clinica),
        (SELECT count(*) FROM registro_auditoria), (SELECT count(*) FROM db_error), (SELECT count(*) FROM bloqueo_agenda);
END
$$;

COMMIT;
ANALYZE;