-- =====================================================================
-- MediCitas - Schema PostgreSQL (requiere PostgreSQL 15 o superior)
-- Multi-tenancy: columna discriminadora id_clinica + RLS por tenant.
--
-- Contexto de conexion (lo fija la aplicacion al inicio de CADA transaccion,
-- con el id_clinica tomado del token ya validado, nunca del cliente):
--     SELECT set_config('app.id_clinica', '42', TRUE);
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------
-- 0. ROLES (menor privilegio alineado con la matriz de permisos)
--    app_medicitas     : rol base de clinica (sujeto a las politicas RLS por tenant)
--    app_plataforma    : administrador de plataforma (solo clinica y usuario;
--                        sin ningun permiso sobre datos clinicos)
--    app_admin_clinica : administrador de clinica (catalogos, usuarios, agenda,
--                        citas, pacientes y lectura de bitacora; sin notas clinicas)
--    app_recepcion     : recepcion (pacientes, agenda y ciclo de citas; sin bitacora
--                        ni notas clinicas ni administracion de usuarios/servicios)
--    app_profesional   : profesional de salud (horarios/bloqueos propios, desenlace,
--                        lectura de pacientes/historial y exclusivo en notas clinicas)
--    Los usuarios de conexion se crean aparte y se agregan con GRANT.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_medicitas') THEN
        CREATE ROLE app_medicitas NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_plataforma') THEN
        CREATE ROLE app_plataforma NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_admin_clinica') THEN
        CREATE ROLE app_admin_clinica NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_recepcion') THEN
        CREATE ROLE app_recepcion NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_profesional') THEN
        CREATE ROLE app_profesional NOLOGIN;
    END IF;
END
$$;

GRANT app_medicitas TO app_admin_clinica, app_recepcion, app_profesional;

-- ---------------------------------------------------------------------
-- 1. TIPOS ENUM
-- ---------------------------------------------------------------------
CREATE TYPE estado_cita      AS ENUM ('reservada', 'atendida', 'ausente', 'cancelada', 'reprogramada');
CREATE TYPE motivo_bloqueo   AS ENUM ('vacaciones', 'permisos');
CREATE TYPE accion_auditoria AS ENUM ('lectura', 'escritura');

-- ---------------------------------------------------------------------
-- 2. FUNCION DE CONTEXTO DEL TENANT
--    Devuelve NULL si el contexto no esta definido: en ese caso las
--    politicas RLS no dejan ver ni escribir ninguna fila (falla segura).
-- ---------------------------------------------------------------------
CREATE FUNCTION app_id_clinica() RETURNS INT
LANGUAGE SQL STABLE AS
$$ SELECT NULLIF(current_setting('app.id_clinica', TRUE), '')::INT $$;

-- ---------------------------------------------------------------------
-- 3. TABLAS GLOBALES (sin id_clinica, PK simple)
-- ---------------------------------------------------------------------
CREATE TABLE clinica (
    id            INT GENERATED ALWAYS AS IDENTITY,
    nombre        VARCHAR(32) NOT NULL,
    zona_horaria  VARCHAR(32) NOT NULL,   -- valores de pg_timezone_names (validado por trigger)
    identificador VARCHAR(32) NOT NULL,
    CONSTRAINT pk_clinica PRIMARY KEY (id),
    CONSTRAINT uq_clinica_identificador UNIQUE (identificador)
);

CREATE TABLE rol (
    id     INT NOT NULL,
    nombre VARCHAR(32) NOT NULL,
    CONSTRAINT pk_rol PRIMARY KEY (id),
    CONSTRAINT uq_rol_nombre UNIQUE (nombre)
);

-- Solo 4 roles (el id 1 es el administrador de plataforma: lo usa ck_usuario_clinica_segun_rol)
INSERT INTO rol (id, nombre) VALUES
    (1, 'administrador plataforma'),
    (2, 'administrador clinica'),
    (3, 'recepcion'),
    (4, 'profesional de salud');

CREATE TABLE especialidad (
    id          INT GENERATED ALWAYS AS IDENTITY,
    nombre      VARCHAR(32) NOT NULL,
    descripcion VARCHAR(64),
    CONSTRAINT pk_especialidad PRIMARY KEY (id),
    CONSTRAINT uq_especialidad_nombre UNIQUE (nombre)
);

-- ---------------------------------------------------------------------
-- 4. GESTION DE USUARIOS
--    PK simple (id): el administrador de plataforma tiene id_clinica NULL.
--    UNIQUE (id_clinica, id) es el destino de las FK compuestas.
-- ---------------------------------------------------------------------
CREATE TABLE usuario (
    id             INT GENERATED ALWAYS AS IDENTITY,
    id_clinica     INT,
    id_rol         INT NOT NULL,
    nombre_usuario VARCHAR(128) NOT NULL,
    correo         VARCHAR(32)  NOT NULL,
    token_sub      VARCHAR(128) NOT NULL,       -- claim "sub" del token del proveedor de identidad
    activo         BOOLEAN NOT NULL DEFAULT TRUE,  -- baja logica (RF2)
    CONSTRAINT pk_usuario PRIMARY KEY (id),
    CONSTRAINT uq_usuario_tenant UNIQUE (id_clinica, id),
    CONSTRAINT uq_usuario_token_sub UNIQUE (token_sub),
    CONSTRAINT uq_usuario_correo UNIQUE (id_clinica, correo),
    CONSTRAINT fk_usuario_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_usuario_rol FOREIGN KEY (id_rol) REFERENCES rol (id),
    -- RF2: solo el administrador de plataforma (rol 1) carece de clinica
    CONSTRAINT ck_usuario_clinica_segun_rol CHECK (
        (id_rol = 1 AND id_clinica IS NULL) OR (id_rol <> 1 AND id_clinica IS NOT NULL)
    )
);
CREATE UNIQUE INDEX uq_usuario_correo_plataforma ON usuario (correo) WHERE id_clinica IS NULL;
CREATE INDEX ix_usuario_id_rol ON usuario (id_rol);

-- ---------------------------------------------------------------------
-- 5. GESTION DE SERVICIOS
-- ---------------------------------------------------------------------
CREATE TABLE servicio (
    id_clinica      INT NOT NULL DEFAULT app_id_clinica(),
    id              INT GENERATED ALWAYS AS IDENTITY,
    id_especialidad INT NOT NULL,
    nombre          VARCHAR(16) NOT NULL,
    duracion_min    INT NOT NULL,
    CONSTRAINT pk_servicio PRIMARY KEY (id_clinica, id),
    CONSTRAINT uq_servicio_nombre UNIQUE (id_clinica, nombre),
    CONSTRAINT fk_servicio_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_servicio_especialidad FOREIGN KEY (id_especialidad) REFERENCES especialidad (id),
    CONSTRAINT ck_servicio_duracion CHECK (duracion_min > 0)
);
CREATE INDEX ix_servicio_especialidad ON servicio (id_clinica, id_especialidad);

-- ---------------------------------------------------------------------
-- 6. GESTION DE PROFESIONALES
-- ---------------------------------------------------------------------
CREATE TABLE profesional (
    id_clinica      INT NOT NULL DEFAULT app_id_clinica(),
    id              INT GENERATED ALWAYS AS IDENTITY,
    id_usuario      INT NOT NULL,
    id_especialidad INT NOT NULL,
    CONSTRAINT pk_profesional PRIMARY KEY (id_clinica, id),
    CONSTRAINT uq_profesional_usuario UNIQUE (id_clinica, id_usuario),
    CONSTRAINT fk_profesional_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_profesional_usuario FOREIGN KEY (id_clinica, id_usuario) REFERENCES usuario (id_clinica, id),
    CONSTRAINT fk_profesional_especialidad FOREIGN KEY (id_especialidad) REFERENCES especialidad (id)
);
CREATE INDEX ix_profesional_especialidad ON profesional (id_clinica, id_especialidad);

CREATE TABLE profesional_x_servicio (
    id_clinica     INT NOT NULL DEFAULT app_id_clinica(),
    id             INT GENERATED ALWAYS AS IDENTITY,
    id_profesional INT NOT NULL,
    id_servicio    INT NOT NULL,
    CONSTRAINT pk_profesional_x_servicio PRIMARY KEY (id_clinica, id),
    CONSTRAINT uq_profesional_x_servicio UNIQUE (id_clinica, id_profesional, id_servicio),
    CONSTRAINT fk_pxs_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_pxs_profesional FOREIGN KEY (id_clinica, id_profesional) REFERENCES profesional (id_clinica, id),
    CONSTRAINT fk_pxs_servicio FOREIGN KEY (id_clinica, id_servicio) REFERENCES servicio (id_clinica, id)
);
CREATE INDEX ix_pxs_servicio ON profesional_x_servicio (id_clinica, id_servicio);

-- Horario semanal en hora LOCAL de la clinica. dia: 1 = lunes ... 7 = domingo (ISO).
-- Varios bloques por dia permitidos (RF5), pero sin solaparse entre si.
CREATE TABLE horario_atencion (
    id_clinica     INT NOT NULL DEFAULT app_id_clinica(),
    id             INT GENERATED ALWAYS AS IDENTITY,
    id_profesional INT NOT NULL,
    dia            INT NOT NULL,
    hora_inicio    TIME NOT NULL,
    hora_fin       TIME NOT NULL,
    CONSTRAINT pk_horario_atencion PRIMARY KEY (id_clinica, id),
    CONSTRAINT fk_horario_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_horario_profesional FOREIGN KEY (id_clinica, id_profesional) REFERENCES profesional (id_clinica, id),
    CONSTRAINT ck_horario_dia CHECK (dia BETWEEN 1 AND 7),
    CONSTRAINT ck_horario_rango CHECK (hora_fin > hora_inicio),
    CONSTRAINT ex_horario_sin_solape EXCLUDE USING gist (
        id_clinica WITH =,
        id_profesional WITH =,
        dia WITH =,
        tsrange(DATE '2000-01-01' + hora_inicio, DATE '2000-01-01' + hora_fin) WITH &&
    )
);
CREATE INDEX ix_horario_profesional_dia ON horario_atencion (id_clinica, id_profesional, dia, hora_inicio);

-- ---------------------------------------------------------------------
-- 7. GESTION DE CITAS
-- ---------------------------------------------------------------------
CREATE TABLE paciente (
    id_clinica       INT NOT NULL DEFAULT app_id_clinica(),
    id               INT GENERATED ALWAYS AS IDENTITY,
    identificacion   VARCHAR(16) NOT NULL,
    nombre           VARCHAR(32) NOT NULL,
    fecha_nacimiento DATE NOT NULL,
    telefono         VARCHAR(20),
    correo           VARCHAR(32),
    CONSTRAINT pk_paciente PRIMARY KEY (id_clinica, id),
    CONSTRAINT uq_paciente_identificacion UNIQUE (id_clinica, identificacion),
    CONSTRAINT fk_paciente_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id)
);

CREATE TABLE cita (
    id_clinica         INT NOT NULL DEFAULT app_id_clinica(),
    id                 INT GENERATED ALWAYS AS IDENTITY,
    id_cita_origen     INT,                       -- cita reprogramada de la que proviene (RF10)
    id_paciente        INT NOT NULL,
    id_profesional     INT NOT NULL,
    id_servicio        INT NOT NULL,
    id_usuario_cancelo INT,
    creada             TIMESTAMPTZ NOT NULL DEFAULT now(),
    estado             estado_cita NOT NULL DEFAULT 'reservada',
    hora_inicio        TIMESTAMPTZ NOT NULL,
    hora_fin           TIMESTAMPTZ NOT NULL,      -- la calcula el trigger a partir del servicio (I4)
    motivo_cancelada   VARCHAR(64),
    CONSTRAINT pk_cita PRIMARY KEY (id_clinica, id),
    CONSTRAINT fk_cita_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_cita_origen FOREIGN KEY (id_clinica, id_cita_origen) REFERENCES cita (id_clinica, id),
    CONSTRAINT fk_cita_paciente FOREIGN KEY (id_clinica, id_paciente) REFERENCES paciente (id_clinica, id),
    CONSTRAINT fk_cita_profesional FOREIGN KEY (id_clinica, id_profesional) REFERENCES profesional (id_clinica, id),
    CONSTRAINT fk_cita_servicio FOREIGN KEY (id_clinica, id_servicio) REFERENCES servicio (id_clinica, id),
    CONSTRAINT fk_cita_usuario_cancelo FOREIGN KEY (id_clinica, id_usuario_cancelo) REFERENCES usuario (id_clinica, id),
    CONSTRAINT ck_cita_rango CHECK (hora_fin > hora_inicio),
    -- RF11: cancelar exige motivo y usuario; en cualquier otro estado no deben existir
    CONSTRAINT ck_cita_cancelacion CHECK (
        (estado = 'cancelada' AND motivo_cancelada IS NOT NULL AND id_usuario_cancelo IS NOT NULL)
        OR (estado <> 'cancelada' AND motivo_cancelada IS NULL AND id_usuario_cancelo IS NULL)
    ),
    -- Ocupan su espacio las citas reservadas y las atendidas: una cita atendida (que solo puede
    -- marcarse desde su hora de inicio) sigue ocupando el resto de su duracion. Las ausentes,
    -- canceladas y reprogramadas lo liberan.
    -- I1: un profesional no tiene dos citas vigentes solapadas
    CONSTRAINT ex_cita_profesional_sin_solape EXCLUDE USING gist (
        id_clinica WITH =, id_profesional WITH =, tstzrange(hora_inicio, hora_fin) WITH &&
    ) WHERE (estado IN ('reservada', 'atendida')),
    -- I2: un paciente no tiene dos citas vigentes solapadas dentro de la clinica
    CONSTRAINT ex_cita_paciente_sin_solape EXCLUDE USING gist (
        id_clinica WITH =, id_paciente WITH =, tstzrange(hora_inicio, hora_fin) WITH &&
    ) WHERE (estado IN ('reservada', 'atendida'))
);
-- RF7 / RF8 / RF20: agenda de un profesional y de toda la clinica
CREATE INDEX ix_cita_profesional_inicio ON cita (id_clinica, id_profesional, hora_inicio) WHERE estado IN ('reservada', 'atendida');
CREATE INDEX ix_cita_agenda_clinica     ON cita (id_clinica, hora_inicio, estado);
-- RF16: historial del paciente (tambien sirve a la FK)
CREATE INDEX ix_cita_paciente_inicio    ON cita (id_clinica, id_paciente, hora_inicio);
-- FK restantes
CREATE INDEX ix_cita_servicio           ON cita (id_clinica, id_servicio);
CREATE INDEX ix_cita_origen             ON cita (id_clinica, id_cita_origen) WHERE id_cita_origen IS NOT NULL;
CREATE INDEX ix_cita_usuario_cancelo    ON cita (id_clinica, id_usuario_cancelo) WHERE id_usuario_cancelo IS NOT NULL;

CREATE TABLE nota_clinica (
    id_clinica     INT NOT NULL DEFAULT app_id_clinica(),
    id             INT GENERATED ALWAYS AS IDENTITY,
    id_cita        INT NOT NULL,
    id_profesional INT NOT NULL,
    contenido      TEXT NOT NULL,
    fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_nota_clinica PRIMARY KEY (id_clinica, id),
    CONSTRAINT uq_nota_clinica_cita UNIQUE (id_clinica, id_cita),   -- una sola nota por cita
    CONSTRAINT fk_nota_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_nota_cita FOREIGN KEY (id_clinica, id_cita) REFERENCES cita (id_clinica, id),
    CONSTRAINT fk_nota_profesional FOREIGN KEY (id_clinica, id_profesional) REFERENCES profesional (id_clinica, id)
);
CREATE INDEX ix_nota_profesional ON nota_clinica (id_clinica, id_profesional);

-- Un bloqueo puede abarcar varios dias (hora_inicio / hora_fin son instantes).
-- id_servicio NULL = bloquea al profesional completo; con valor = solo ese servicio, y solo se
-- admite si el profesional es el unico de la clinica habilitado para ese servicio (trigger 9.8).
CREATE TABLE bloqueo_agenda (
    id_clinica     INT NOT NULL DEFAULT app_id_clinica(),
    id             INT GENERATED ALWAYS AS IDENTITY,
    id_profesional INT NOT NULL,
    id_servicio    INT,
    id_usuario     INT NOT NULL,                -- usuario que registro el bloqueo
    hora_inicio    TIMESTAMPTZ NOT NULL,
    hora_fin       TIMESTAMPTZ NOT NULL,
    motivo         motivo_bloqueo NOT NULL,
    CONSTRAINT pk_bloqueo_agenda PRIMARY KEY (id_clinica, id),
    CONSTRAINT fk_bloqueo_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_bloqueo_profesional FOREIGN KEY (id_clinica, id_profesional) REFERENCES profesional (id_clinica, id),
    CONSTRAINT fk_bloqueo_servicio FOREIGN KEY (id_clinica, id_servicio) REFERENCES servicio (id_clinica, id),
    CONSTRAINT fk_bloqueo_usuario FOREIGN KEY (id_clinica, id_usuario) REFERENCES usuario (id_clinica, id),
    CONSTRAINT ck_bloqueo_rango CHECK (hora_fin > hora_inicio)
);
CREATE INDEX ix_bloqueo_profesional_rango ON bloqueo_agenda
    USING gist (id_clinica, id_profesional, tstzrange(hora_inicio, hora_fin));
CREATE INDEX ix_bloqueo_servicio ON bloqueo_agenda (id_clinica, id_servicio) WHERE id_servicio IS NOT NULL;
CREATE INDEX ix_bloqueo_usuario  ON bloqueo_agenda (id_clinica, id_usuario);

-- ---------------------------------------------------------------------
-- 8. AUDITORIA (append-only)
--    info_usada: nombres de los campos leidos o escritos (nunca los valores).
-- ---------------------------------------------------------------------
CREATE TABLE registro_auditoria (
    id_clinica        INT NOT NULL DEFAULT app_id_clinica(),
    id                BIGINT GENERATED ALWAYS AS IDENTITY,
    id_usuario        INT NOT NULL,
    id_paciente       INT NOT NULL,
    id_nota_clinica   INT,
    accion            accion_auditoria NOT NULL,
    info_usada        TEXT NOT NULL,
    estampa_de_tiempo TIMESTAMPTZ NOT NULL DEFAULT now(),
    ip                INET,
    CONSTRAINT pk_registro_auditoria PRIMARY KEY (id_clinica, id),
    CONSTRAINT fk_auditoria_clinica FOREIGN KEY (id_clinica) REFERENCES clinica (id),
    CONSTRAINT fk_auditoria_usuario FOREIGN KEY (id_clinica, id_usuario) REFERENCES usuario (id_clinica, id),
    CONSTRAINT fk_auditoria_paciente FOREIGN KEY (id_clinica, id_paciente) REFERENCES paciente (id_clinica, id),
    CONSTRAINT fk_auditoria_nota FOREIGN KEY (id_clinica, id_nota_clinica) REFERENCES nota_clinica (id_clinica, id)
);
-- RF19: filtros por usuario, por paciente y por rango de fechas
CREATE INDEX ix_auditoria_fecha    ON registro_auditoria (id_clinica, estampa_de_tiempo);
CREATE INDEX ix_auditoria_usuario  ON registro_auditoria (id_clinica, id_usuario, estampa_de_tiempo);
CREATE INDEX ix_auditoria_paciente ON registro_auditoria (id_clinica, id_paciente, estampa_de_tiempo);
CREATE INDEX ix_auditoria_nota     ON registro_auditoria (id_clinica, id_nota_clinica) WHERE id_nota_clinica IS NOT NULL;

-- ---------------------------------------------------------------------
-- 8.1 DB_ERROR: equivalente en PostgreSQL de dbo.DBError (SQL Server)
--     error_number   : codigo de salida (OutResult) que el SP asigna al error
--                      (PostgreSQL no tiene un numero de error entero; usa SQLSTATE)
--     error_state    : SQLSTATE de PostgreSQL (ej. '23P01')
--     error_severity : siempre 'ERROR' (las excepciones capturables en PL/pgSQL son nivel ERROR)
--     error_line / error_procedure: se extraen del contexto de la excepcion
--     Sin RLS ni columna de tenant: la aplicacion solo tiene INSERT (no lee la tabla).
-- ---------------------------------------------------------------------
CREATE TABLE db_error (
    error_id        INT GENERATED ALWAYS AS IDENTITY,
    user_name       VARCHAR(100),
    error_number    INT,
    error_state     VARCHAR(5),
    error_severity  VARCHAR(16),
    error_line      INT,
    error_procedure TEXT,
    error_message   TEXT,
    error_datetime  TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT pk_db_error PRIMARY KEY (error_id)
);
CREATE INDEX ix_db_error_fecha ON db_error (error_datetime);

-- =====================================================================
-- 9. TRIGGERS Y FUNCIONES DE INTEGRIDAD
-- =====================================================================

-- 9.1 La zona horaria de la clinica debe existir en pg_timezone_names
CREATE FUNCTION fn_clinica_zona_horaria() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.zona_horaria) THEN
        RAISE EXCEPTION 'Zona horaria invalida: %', NEW.zona_horaria USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_clinica_zona_horaria
    BEFORE INSERT OR UPDATE OF zona_horaria ON clinica
    FOR EACH ROW EXECUTE FUNCTION fn_clinica_zona_horaria();

-- 9.2 Un profesional debe estar ligado a un usuario con rol "profesional de salud" (id 4)
CREATE FUNCTION fn_profesional_rol_usuario() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM usuario u
        WHERE u.id_clinica = NEW.id_clinica AND u.id = NEW.id_usuario AND u.id_rol = 4
    ) THEN
        RAISE EXCEPTION 'El usuario % no tiene el rol de profesional de salud', NEW.id_usuario
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_profesional_rol_usuario
    BEFORE INSERT OR UPDATE OF id_usuario ON profesional
    FOR EACH ROW EXECUTE FUNCTION fn_profesional_rol_usuario();

-- 9.3 Alta de cita: calcula hora_fin (I4) y valida RF4, RF9 e I3.
--     I1 e I2 los garantizan las restricciones EXCLUDE de la tabla.
CREATE FUNCTION fn_cita_before_insert() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
DECLARE
    v_duracion   INT;
    v_zona       VARCHAR(32);
    v_inicio_loc TIMESTAMP;
    v_fin_loc    TIMESTAMP;
    v_estado_ori estado_cita;
BEGIN
    IF NEW.estado <> 'reservada' THEN
        RAISE EXCEPTION 'Toda cita nace en estado reservada' USING ERRCODE = 'check_violation';
    END IF;

    -- RF9: no se reservan citas en el pasado
    IF NEW.hora_inicio <= now() THEN
        RAISE EXCEPTION 'No se puede reservar una cita en el pasado' USING ERRCODE = 'check_violation';
    END IF;

    -- I4: la duracion la determina el servicio
    SELECT s.duracion_min INTO v_duracion
    FROM servicio s
    WHERE s.id_clinica = NEW.id_clinica AND s.id = NEW.id_servicio;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Servicio % inexistente en la clinica', NEW.id_servicio
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    NEW.hora_fin := NEW.hora_inicio + make_interval(mins => v_duracion);

    -- RF4: el profesional debe estar habilitado para el servicio
    IF NOT EXISTS (
        SELECT 1 FROM profesional_x_servicio p
        WHERE p.id_clinica = NEW.id_clinica
          AND p.id_profesional = NEW.id_profesional
          AND p.id_servicio = NEW.id_servicio
    ) THEN
        RAISE EXCEPTION 'El profesional % no esta habilitado para el servicio %',
            NEW.id_profesional, NEW.id_servicio USING ERRCODE = 'check_violation';
    END IF;

    -- I3 (parte 1): la cita cae completa dentro de un bloque del horario (hora local de la clinica)
    SELECT c.zona_horaria INTO v_zona FROM clinica c WHERE c.id = NEW.id_clinica;
    v_inicio_loc := NEW.hora_inicio AT TIME ZONE v_zona;
    v_fin_loc    := NEW.hora_fin    AT TIME ZONE v_zona;
    IF v_inicio_loc::DATE <> v_fin_loc::DATE OR NOT EXISTS (
        SELECT 1 FROM horario_atencion h
        WHERE h.id_clinica = NEW.id_clinica
          AND h.id_profesional = NEW.id_profesional
          AND h.dia = EXTRACT(ISODOW FROM v_inicio_loc)::INT
          AND h.hora_inicio <= v_inicio_loc::TIME
          AND h.hora_fin    >= v_fin_loc::TIME
    ) THEN
        RAISE EXCEPTION 'La cita queda fuera del horario de atencion del profesional'
            USING ERRCODE = 'check_violation';
    END IF;

    -- I3 (parte 2): la cita no se solapa con bloqueos del profesional
    IF EXISTS (
        SELECT 1 FROM bloqueo_agenda b
        WHERE b.id_clinica = NEW.id_clinica
          AND b.id_profesional = NEW.id_profesional
          AND (b.id_servicio IS NULL OR b.id_servicio = NEW.id_servicio)
          AND tstzrange(b.hora_inicio, b.hora_fin) && tstzrange(NEW.hora_inicio, NEW.hora_fin)
    ) THEN
        RAISE EXCEPTION 'El espacio solicitado esta bloqueado en la agenda del profesional'
            USING ERRCODE = 'check_violation';
    END IF;

    -- RF10: una cita con origen solo puede crearse cuando el origen ya esta reprogramado
    IF NEW.id_cita_origen IS NOT NULL THEN
        SELECT o.estado INTO v_estado_ori
        FROM cita o WHERE o.id_clinica = NEW.id_clinica AND o.id = NEW.id_cita_origen;
        IF v_estado_ori IS DISTINCT FROM 'reprogramada' THEN
            RAISE EXCEPTION 'La cita de origen debe estar en estado reprogramada'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN NEW;
END
$$;
CREATE TRIGGER trg_cita_before_insert
    BEFORE INSERT ON cita
    FOR EACH ROW EXECUTE FUNCTION fn_cita_before_insert();

-- 9.4 Actualizacion de cita: datos inmutables (I4) y transiciones validas (RF12, RF13)
CREATE FUNCTION fn_cita_before_update() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    IF ROW(NEW.id_clinica, NEW.id, NEW.id_cita_origen, NEW.id_paciente, NEW.id_profesional,
           NEW.id_servicio, NEW.hora_inicio, NEW.hora_fin, NEW.creada)
       IS DISTINCT FROM
       ROW(OLD.id_clinica, OLD.id, OLD.id_cita_origen, OLD.id_paciente, OLD.id_profesional,
           OLD.id_servicio, OLD.hora_inicio, OLD.hora_fin, OLD.creada) THEN
        RAISE EXCEPTION 'Los datos de la cita no se modifican; para moverla se reprograma'
            USING ERRCODE = 'check_violation';
    END IF;

    -- RF13: los estados finales no admiten salida ni cambios
    IF OLD.estado <> 'reservada' THEN
        RAISE EXCEPTION 'La cita % esta en estado final (%) y no admite cambios', OLD.id, OLD.estado
            USING ERRCODE = 'check_violation';
    END IF;

    -- RF12: atendida o ausente solo una vez pasada la hora de inicio
    IF NEW.estado IN ('atendida', 'ausente') AND now() < OLD.hora_inicio THEN
        RAISE EXCEPTION 'No se puede registrar el desenlace antes de la hora de inicio'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END
$$;
CREATE TRIGGER trg_cita_before_update
    BEFORE UPDATE ON cita
    FOR EACH ROW EXECUTE FUNCTION fn_cita_before_update();

-- 9.5 RF10: una cita reprogramada debe tener su cita sucesora al cerrar la transaccion
CREATE FUNCTION fn_cita_reprogramada_con_sucesora() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM cita s WHERE s.id_clinica = NEW.id_clinica AND s.id_cita_origen = NEW.id
    ) THEN
        RAISE EXCEPTION 'La cita % quedo reprogramada sin una cita sucesora', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;
CREATE CONSTRAINT TRIGGER trg_cita_reprogramada_con_sucesora
    AFTER UPDATE OF estado ON cita
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (NEW.estado = 'reprogramada')
    EXECUTE FUNCTION fn_cita_reprogramada_con_sucesora();

-- 9.6 RF15: la nota solo puede escribirla el profesional que atendio una cita atendida
CREATE FUNCTION fn_nota_before_insert() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
DECLARE
    v_estado         estado_cita;
    v_id_profesional INT;
BEGIN
    SELECT c.estado, c.id_profesional INTO v_estado, v_id_profesional
    FROM cita c
    WHERE c.id_clinica = NEW.id_clinica AND c.id = NEW.id_cita;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cita % inexistente', NEW.id_cita USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_estado <> 'atendida' THEN
        RAISE EXCEPTION 'La nota clinica solo se adjunta a citas atendidas' USING ERRCODE = 'check_violation';
    END IF;
    IF v_id_profesional <> NEW.id_profesional THEN
        RAISE EXCEPTION 'La nota solo la escribe el profesional que atendio la cita'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_nota_before_insert
    BEFORE INSERT ON nota_clinica
    FOR EACH ROW EXECUTE FUNCTION fn_nota_before_insert();

-- 9.7 I6: la bitacora no admite modificacion ni borrado (ni siquiera del dueno de la tabla)
CREATE FUNCTION fn_auditoria_inmutable() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    RAISE EXCEPTION 'registro_auditoria es append-only: % no permitido', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END
$$;
CREATE TRIGGER trg_auditoria_sin_modificar
    BEFORE UPDATE OR DELETE ON registro_auditoria
    FOR EACH ROW EXECUTE FUNCTION fn_auditoria_inmutable();
CREATE TRIGGER trg_auditoria_sin_truncar
    BEFORE TRUNCATE ON registro_auditoria
    FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_inmutable();

-- 9.8 Un bloqueo de un servicio puntual solo se admite si el profesional esta habilitado para ese
--     servicio y es el unico de la clinica que lo brinda
CREATE FUNCTION fn_bloqueo_servicio_unico() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.id_servicio IS NOT NULL THEN
        IF NOT EXISTS (
               SELECT 1 FROM profesional_x_servicio x
               WHERE x.id_clinica = NEW.id_clinica
                 AND x.id_profesional = NEW.id_profesional
                 AND x.id_servicio = NEW.id_servicio)
           OR EXISTS (
               SELECT 1 FROM profesional_x_servicio x
               WHERE x.id_clinica = NEW.id_clinica
                 AND x.id_servicio = NEW.id_servicio
                 AND x.id_profesional <> NEW.id_profesional) THEN
            RAISE EXCEPTION 'El servicio solo se bloquea si el profesional es el unico habilitado para atenderlo'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_bloqueo_servicio_unico
    BEFORE INSERT OR UPDATE OF id_profesional, id_servicio ON bloqueo_agenda
    FOR EACH ROW EXECUTE FUNCTION fn_bloqueo_servicio_unico();

-- =====================================================================
-- 10. ROW LEVEL SECURITY (aislamiento por tenant, I5)
-- =====================================================================

-- 10.1 Tablas con id_clinica NOT NULL: lectura y escritura solo del tenant del contexto
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'servicio', 'profesional', 'profesional_x_servicio', 'horario_atencion',
        'paciente', 'cita', 'nota_clinica', 'bloqueo_agenda'
    ]
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format(
            'CREATE POLICY pol_tenant ON %I FOR ALL TO app_medicitas
               USING (id_clinica = (SELECT app_id_clinica()))
               WITH CHECK (id_clinica = (SELECT app_id_clinica()))', t);
    END LOOP;
END
$$;

-- 10.2 Auditoria: solo SELECT e INSERT (sin politicas de UPDATE ni DELETE)
ALTER TABLE registro_auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE registro_auditoria FORCE ROW LEVEL SECURITY;
CREATE POLICY pol_tenant_select ON registro_auditoria FOR SELECT TO app_medicitas
    USING (id_clinica = (SELECT app_id_clinica()));
CREATE POLICY pol_tenant_insert ON registro_auditoria FOR INSERT TO app_medicitas
    WITH CHECK (id_clinica = (SELECT app_id_clinica()));

-- 10.3 Usuario: la aplicacion ve solo su tenant; la plataforma opera sobre todos
ALTER TABLE usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario FORCE ROW LEVEL SECURITY;
CREATE POLICY pol_tenant ON usuario FOR ALL TO app_medicitas
    USING (id_clinica = (SELECT app_id_clinica()))
    WITH CHECK (id_clinica = (SELECT app_id_clinica()));
CREATE POLICY pol_plataforma ON usuario FOR ALL TO app_plataforma
    USING (TRUE) WITH CHECK (TRUE);

-- 10.4 Clinica: la aplicacion solo lee la suya; la plataforma las gestiona (RF1)
ALTER TABLE clinica ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinica FORCE ROW LEVEL SECURITY;
CREATE POLICY pol_tenant ON clinica FOR SELECT TO app_medicitas
    USING (id = (SELECT app_id_clinica()));
CREATE POLICY pol_plataforma ON clinica FOR ALL TO app_plataforma
    USING (TRUE) WITH CHECK (TRUE);

-- =====================================================================
-- 11. PRIVILEGIOS (menor privilegio por perfil alineado con la matriz)
-- =====================================================================
GRANT USAGE ON SCHEMA public TO app_medicitas, app_plataforma, app_admin_clinica, app_recepcion, app_profesional;

-- Catalogos globales
GRANT SELECT ON rol, especialidad TO app_medicitas, app_plataforma;
GRANT INSERT ON especialidad TO app_admin_clinica;

-- Plataforma: unicamente clinica y usuario (ningun dato clinico)
GRANT SELECT, INSERT, UPDATE ON clinica, usuario TO app_plataforma;

-- Permisos comunes de clinica (heredados de app_medicitas)
GRANT SELECT ON clinica TO app_medicitas;
GRANT INSERT ON registro_auditoria, db_error TO app_medicitas, app_plataforma;

-- Perfil Administrador de Clinica: gestiona usuarios, servicios, profesionales, horarios, bloqueos,
-- pacientes, citas y es el UNICO con SELECT en registro_auditoria (sin acceso a nota_clinica)
GRANT SELECT, INSERT, UPDATE ON usuario, servicio, profesional, paciente, cita TO app_admin_clinica;
GRANT SELECT, INSERT, UPDATE, DELETE ON profesional_x_servicio, horario_atencion, bloqueo_agenda TO app_admin_clinica;
GRANT SELECT ON registro_auditoria TO app_admin_clinica;

-- Perfil Recepcion: opera pacientes y citas, lee catalogos/agenda (sin SELECT en registro_auditoria ni nota_clinica)
GRANT SELECT ON usuario, servicio, profesional, profesional_x_servicio, horario_atencion, bloqueo_agenda TO app_recepcion;
GRANT SELECT, INSERT, UPDATE ON paciente, cita TO app_recepcion;

-- Perfil Profesional: lectura de pacientes/catalogos, propios horarios/bloqueos, desenlace en cita
-- y UNICO con SELECT e INSERT en nota_clinica (sin SELECT en registro_auditoria)
GRANT SELECT ON usuario, servicio, profesional, profesional_x_servicio, paciente TO app_profesional;
GRANT SELECT, UPDATE ON cita TO app_profesional;
GRANT SELECT, INSERT, UPDATE, DELETE ON horario_atencion, bloqueo_agenda TO app_profesional;
GRANT SELECT, INSERT ON nota_clinica TO app_profesional;

-- I6: refuerzo a nivel de privilegios (ademas del trigger y de RLS)
REVOKE UPDATE, DELETE, TRUNCATE ON registro_auditoria FROM app_medicitas, app_plataforma, app_admin_clinica, app_recepcion, app_profesional;

-- =====================================================================
-- 12. PROCEDIMIENTOS ALMACENADOS
--
-- Convenciones
--   * Parametros de entrada con prefijo In y de salida con prefijo Out (PostgreSQL pasa los
--     identificadores sin comillas a minusculas: InIdCita se almacena como inidcita).
--   * OutResult (siempre el ultimo parametro): 0 = exito; 403 = sin permiso o sin contexto de
--     tenant; 404 = no encontrado; 409 = conflicto (solape o duplicado); 422 = dato o regla de
--     negocio invalida; 500 = error inesperado. Todo error capturado se registra en db_error.
--   * Los SP que consultan devuelven el resultado en OutCursor (REFCURSOR), que solo vive dentro
--     de la transaccion que hizo el CALL.
--
-- Uso desde el backend (una sola transaccion por solicitud):
--     BEGIN;
--     SELECT set_config('app.id_clinica', '42', TRUE);
--     CALL SP_ReservarCita('rec01', 10, 3, 2, '2026-11-02 09:00-06', NULL, NULL);
--         -- devuelve una fila: (outidcita, outresult)
--     CALL SP_ConsultarAgendaDia('rec01', '2026-11-02', NULL, NULL, NULL);
--         -- devuelve (outcursor, outresult); luego, en la MISMA transaccion:
--     FETCH ALL FROM "<nombre devuelto en outcursor>";
--     COMMIT;     -- se hace COMMIT tambien cuando OutResult <> 0, para conservar db_error
-- =====================================================================

-- RF1 - Alta de clinica con su primer administrador (rol app_plataforma)
CREATE OR REPLACE PROCEDURE SP_AltaClinica(
      InUserName VARCHAR(100)
    , InNombre VARCHAR(32)
    , InZonaHoraria VARCHAR(32)
    , InIdentificador VARCHAR(32)
    , InNombreAdmin VARCHAR(128)
    , InCorreoAdmin VARCHAR(32)
    , InTokenSubAdmin VARCHAR(128)
    , OUT OutIdClinica INT
    , OUT OutIdUsuarioAdmin INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        INSERT INTO clinica (nombre, zona_horaria, identificador)
        VALUES (InNombre, InZonaHoraria, InIdentificador)
        RETURNING id INTO OutIdClinica;

        -- El primer usuario de la clinica es su administrador (rol 2)
        INSERT INTO usuario (id_clinica, id_rol, nombre_usuario, correo, token_sub)
        VALUES (OutIdClinica, 2, InNombreAdmin, InCorreoAdmin, InTokenSubAdmin)
        RETURNING id INTO OutIdUsuarioAdmin;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdClinica := NULL;
            OutIdUsuarioAdmin := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_AltaClinica')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF2 - Alta de usuario de la clinica
CREATE OR REPLACE PROCEDURE SP_CrearUsuario(
      InUserName VARCHAR(100)
    , InNombreUsuario VARCHAR(128)
    , InCorreo VARCHAR(32)
    , InTokenSub VARCHAR(128)
    , InIdRol INT
    , OUT OutIdUsuario INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        INSERT INTO usuario (id_clinica, id_rol, nombre_usuario, correo, token_sub)
        VALUES (app_id_clinica(), InIdRol, InNombreUsuario, InCorreo, InTokenSub)
        RETURNING id INTO OutIdUsuario;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdUsuario := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CrearUsuario')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF2 - Asignacion de rol
CREATE OR REPLACE PROCEDURE SP_CambiarRolUsuario(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIdRol INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF InIdRol <> 4 AND EXISTS (
            SELECT 1 FROM profesional p
            WHERE p.id_clinica = app_id_clinica() AND p.id_usuario = InIdUsuario
        ) THEN
            RAISE EXCEPTION 'El usuario % tiene un profesional asociado', InIdUsuario
                USING ERRCODE = 'unique_violation';
        END IF;

        UPDATE usuario SET id_rol = InIdRol, activo = TRUE
        WHERE id_clinica = app_id_clinica() AND id = InIdUsuario;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CambiarRolUsuario')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF2 - Baja logica de usuario
CREATE OR REPLACE PROCEDURE SP_DarBajaUsuario(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        UPDATE usuario SET activo = FALSE
        WHERE id_clinica = app_id_clinica() AND id = InIdUsuario;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_DarBajaUsuario')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF3 - Alta de servicio en el catalogo de la clinica
CREATE OR REPLACE PROCEDURE SP_CrearServicio(
      InUserName VARCHAR(100)
    , InNombre VARCHAR(16)
    , InDuracionMin INT
    , InIdEspecialidad INT
    , OUT OutIdServicio INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        INSERT INTO servicio (nombre, duracion_min, id_especialidad)
        VALUES (InNombre, InDuracionMin, InIdEspecialidad)
        RETURNING id INTO OutIdServicio;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdServicio := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CrearServicio')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF3 - Actualizacion de servicio
CREATE OR REPLACE PROCEDURE SP_ActualizarServicio(
      InUserName VARCHAR(100)
    , InIdServicio INT
    , InNombre VARCHAR(16)
    , InDuracionMin INT
    , InIdEspecialidad INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- Las citas ya reservadas conservan su duracion (hora_fin se fija al reservar, I4)
        UPDATE servicio
        SET nombre = InNombre, duracion_min = InDuracionMin, id_especialidad = InIdEspecialidad
        WHERE id_clinica = app_id_clinica() AND id = InIdServicio;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ActualizarServicio')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF4 - Alta de profesional con su especialidad
CREATE OR REPLACE PROCEDURE SP_CrearProfesional(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIdEspecialidad INT
    , OUT OutIdProfesional INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        INSERT INTO profesional (id_usuario, id_especialidad)
        VALUES (InIdUsuario, InIdEspecialidad)
        RETURNING id INTO OutIdProfesional;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdProfesional := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CrearProfesional')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF4 - Habilitar un servicio para un profesional
CREATE OR REPLACE PROCEDURE SP_AsignarServicioProfesional(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , InIdServicio INT
    , OUT OutIdProfesionalXServicio INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        INSERT INTO profesional_x_servicio (id_profesional, id_servicio)
        VALUES (InIdProfesional, InIdServicio)
        RETURNING id INTO OutIdProfesionalXServicio;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdProfesionalXServicio := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_AsignarServicioProfesional')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF4 - Deshabilitar un servicio para un profesional
CREATE OR REPLACE PROCEDURE SP_QuitarServicioProfesional(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , InIdServicio INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        DELETE FROM profesional_x_servicio
        WHERE id_clinica = app_id_clinica()
          AND id_profesional = InIdProfesional
          AND id_servicio = InIdServicio;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_QuitarServicioProfesional')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF5 - Agregar un bloque de horario semanal
CREATE OR REPLACE PROCEDURE SP_AgregarHorarioAtencion(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , InDia INT
    , InHoraInicio TIME
    , InHoraFin TIME
    , OUT OutIdHorario INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- InDia: 1 = lunes ... 7 = domingo. Varios bloques por dia, sin solaparse.
        INSERT INTO horario_atencion (id_profesional, dia, hora_inicio, hora_fin)
        VALUES (InIdProfesional, InDia, InHoraInicio, InHoraFin)
        RETURNING id INTO OutIdHorario;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdHorario := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_AgregarHorarioAtencion')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF5 - Eliminar un bloque de horario
CREATE OR REPLACE PROCEDURE SP_EliminarHorarioAtencion(
      InUserName VARCHAR(100)
    , InIdHorario INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF EXISTS (
            SELECT 1 FROM horario_atencion h
            JOIN cita c ON c.id_clinica = h.id_clinica AND c.id_profesional = h.id_profesional
            WHERE h.id_clinica = app_id_clinica() AND h.id = InIdHorario AND c.estado = 'reservada'
        ) THEN
            RAISE EXCEPTION 'Reprograme las citas vigentes antes de retirar horarios'
                USING ERRCODE = 'exclusion_violation';
        END IF;

        DELETE FROM horario_atencion
        WHERE id_clinica = app_id_clinica() AND id = InIdHorario;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_EliminarHorarioAtencion')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF6 - Registrar bloqueo de agenda (devuelve cuantas citas quedan en conflicto)
CREATE OR REPLACE PROCEDURE SP_RegistrarBloqueoAgenda(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , InIdServicio INT
    , InIdUsuario INT
    , InHoraInicio TIMESTAMPTZ
    , InHoraFin TIMESTAMPTZ
    , InMotivo VARCHAR(16)
    , OUT OutIdBloqueo INT
    , OUT OutCantidadConflictos INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- InIdServicio NULL = bloquea al profesional completo; con valor, solo ese servicio y solo si el
        -- profesional es el unico de la clinica que lo brinda (trigger). InMotivo: vacaciones | permisos
        INSERT INTO bloqueo_agenda (id_profesional, id_servicio, id_usuario, hora_inicio, hora_fin, motivo)
        VALUES (InIdProfesional, InIdServicio, InIdUsuario, InHoraInicio, InHoraFin, InMotivo::motivo_bloqueo)
        RETURNING id INTO OutIdBloqueo;

        -- El bloqueo NO cancela citas: solo se cuentan las que quedan en conflicto
        SELECT COUNT(*) INTO OutCantidadConflictos
        FROM cita c
        WHERE c.id_clinica = app_id_clinica()
          AND c.id_profesional = InIdProfesional
          AND c.estado = 'reservada'
          AND (InIdServicio IS NULL OR c.id_servicio = InIdServicio)
          AND tstzrange(c.hora_inicio, c.hora_fin) && tstzrange(InHoraInicio, InHoraFin);
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdBloqueo := NULL;
            OutCantidadConflictos := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_RegistrarBloqueoAgenda')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF6 - Citas reservadas en conflicto con un bloqueo (cursor)
CREATE OR REPLACE PROCEDURE SP_ListarConflictosBloqueo(
      InUserName VARCHAR(100)
    , InIdBloqueo INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vIdProfesional INT;
    vIdServicio INT;
    vHoraInicio TIMESTAMPTZ;
    vHoraFin TIMESTAMPTZ;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        SELECT b.id_profesional, b.id_servicio, b.hora_inicio, b.hora_fin
        INTO vIdProfesional, vIdServicio, vHoraInicio, vHoraFin
        FROM bloqueo_agenda b
        WHERE b.id_clinica = app_id_clinica() AND b.id = InIdBloqueo;
        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;

        OPEN OutCursor FOR
            SELECT c.id AS id_cita, c.id_paciente, p.nombre AS paciente, c.id_servicio,
                   s.nombre AS servicio, c.hora_inicio, c.hora_fin
            FROM cita c
            JOIN paciente p ON p.id_clinica = c.id_clinica AND p.id = c.id_paciente
            JOIN servicio s ON s.id_clinica = c.id_clinica AND s.id = c.id_servicio
            WHERE c.id_clinica = app_id_clinica()
              AND c.id_profesional = vIdProfesional
              AND c.estado = 'reservada'
              AND (vIdServicio IS NULL OR c.id_servicio = vIdServicio)
              AND tstzrange(c.hora_inicio, c.hora_fin) && tstzrange(vHoraInicio, vHoraFin)
            ORDER BY c.hora_inicio;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ListarConflictosBloqueo')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF8 - Profesionales con espacio para un servicio en un rango de fechas (cursor)
CREATE OR REPLACE PROCEDURE SP_ConsultarDisponibilidadServicio(
      InUserName VARCHAR(100)
    , InIdServicio INT
    , InFechaDesde DATE
    , InFechaHasta DATE
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vDuracion INT;
    vZona VARCHAR(32);
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF InFechaDesde IS NULL OR InFechaHasta IS NULL
           OR InFechaHasta < InFechaDesde OR InFechaHasta - InFechaDesde > 61 THEN
            OutResult := 422;   -- rango invalido (maximo 62 dias)
            RETURN;
        END IF;

        SELECT s.duracion_min INTO vDuracion
        FROM servicio s
        WHERE s.id_clinica = app_id_clinica() AND s.id = InIdServicio;
        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;

        SELECT c.zona_horaria INTO vZona FROM clinica c WHERE c.id = app_id_clinica();

        -- Espacios: cada bloque del horario se divide en tramos consecutivos de la duracion del servicio,
        -- a partir del inicio del bloque (hora local de la clinica).
        -- RF8 se consulta siempre al motor relacional (no pasa por la cache de Redis, que solo sirve RF7),
        -- por lo que nunca puede contradecir el estado de la base (I8).
        OPEN OutCursor FOR
            WITH espacios AS (
                SELECT h.id_profesional,
                       (g.t AT TIME ZONE vZona) AS hora_inicio
                FROM generate_series(InFechaDesde::TIMESTAMP, InFechaHasta::TIMESTAMP, INTERVAL '1 day') AS d(dia)
                JOIN horario_atencion h
                  ON h.id_clinica = app_id_clinica()
                 AND h.dia = EXTRACT(ISODOW FROM d.dia)::INT
                JOIN profesional_x_servicio x
                  ON x.id_clinica = h.id_clinica
                 AND x.id_profesional = h.id_profesional
                 AND x.id_servicio = InIdServicio
                CROSS JOIN LATERAL generate_series(
                    d.dia + h.hora_inicio,
                    d.dia + h.hora_fin - make_interval(mins => vDuracion),
                    make_interval(mins => vDuracion)) AS g(t)
            )
            SELECT e.id_profesional,
                   u.nombre_usuario AS profesional,
                   COUNT(*) AS espacios_libres,
                   MIN(e.hora_inicio) AS primer_espacio,
                   ARRAY_AGG(e.hora_inicio ORDER BY e.hora_inicio) AS espacios
            FROM espacios e
            JOIN profesional p ON p.id_clinica = app_id_clinica() AND p.id = e.id_profesional
            JOIN usuario u ON u.id_clinica = p.id_clinica AND u.id = p.id_usuario
            WHERE e.hora_inicio > now()
              AND NOT EXISTS (
                  SELECT 1 FROM cita c
                  WHERE c.id_clinica = app_id_clinica()
                    AND c.id_profesional = e.id_profesional
                    AND c.estado IN ('reservada', 'atendida')
                    AND tstzrange(c.hora_inicio, c.hora_fin)
                        && tstzrange(e.hora_inicio, e.hora_inicio + make_interval(mins => vDuracion)))
              AND NOT EXISTS (
                  SELECT 1 FROM bloqueo_agenda b
                  WHERE b.id_clinica = app_id_clinica()
                    AND b.id_profesional = e.id_profesional
                    AND (b.id_servicio IS NULL OR b.id_servicio = InIdServicio)
                    AND tstzrange(b.hora_inicio, b.hora_fin)
                        && tstzrange(e.hora_inicio, e.hora_inicio + make_interval(mins => vDuracion)))
            GROUP BY e.id_profesional, u.nombre_usuario
            ORDER BY primer_espacio, u.nombre_usuario;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ConsultarDisponibilidadServicio')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF9 - Reservar una cita
CREATE OR REPLACE PROCEDURE SP_ReservarCita(
      InUserName VARCHAR(100)
    , InIdPaciente INT
    , InIdProfesional INT
    , InIdServicio INT
    , InHoraInicio TIMESTAMPTZ
    , OUT OutIdCita INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- hora_fin es un marcador: el trigger la recalcula con la duracion del servicio (I4).
        -- Solapes (I1, I2) -> SQLSTATE 23P01 -> OutResult 409
        INSERT INTO cita (id_paciente, id_profesional, id_servicio, hora_inicio, hora_fin)
        VALUES (InIdPaciente, InIdProfesional, InIdServicio, InHoraInicio, InHoraInicio)
        RETURNING id INTO OutIdCita;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdCita := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ReservarCita')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF10 - Reprogramar una cita vigente (atomico)
CREATE OR REPLACE PROCEDURE SP_ReprogramarCita(
      InUserName VARCHAR(100)
    , InIdCita INT
    , InNuevaHoraInicio TIMESTAMPTZ
    , InNuevoIdProfesional INT
    , OUT OutIdCitaNueva INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vIdClinica INT;
    vEstado estado_cita;
    vIdPaciente INT;
    vIdProfesional INT;
    vIdServicio INT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- InNuevoIdProfesional NULL = se conserva el profesional
        SELECT c.id_clinica, c.estado, c.id_paciente, c.id_profesional, c.id_servicio
        INTO vIdClinica, vEstado, vIdPaciente, vIdProfesional, vIdServicio
        FROM cita c
        WHERE c.id_clinica = app_id_clinica() AND c.id = InIdCita
        FOR UPDATE;
        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;
        IF vEstado <> 'reservada' THEN
            OutResult := 422;   -- solo se reprograma una cita vigente
            RETURN;
        END IF;

        -- Primero se libera el espacio anterior y luego se ocupa el nuevo, en la misma transaccion
        UPDATE cita SET estado = 'reprogramada'
        WHERE id_clinica = vIdClinica AND id = InIdCita;

        INSERT INTO cita (id_cita_origen, id_paciente, id_profesional, id_servicio, hora_inicio, hora_fin)
        VALUES (InIdCita, vIdPaciente, COALESCE(InNuevoIdProfesional, vIdProfesional),
                vIdServicio, InNuevaHoraInicio, InNuevaHoraInicio)
        RETURNING id INTO OutIdCitaNueva;

        -- Se valida aqui (y no en el COMMIT) que la cita reprogramada tiene sucesora
        SET CONSTRAINTS trg_cita_reprogramada_con_sucesora IMMEDIATE;
        SET CONSTRAINTS trg_cita_reprogramada_con_sucesora DEFERRED;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdCitaNueva := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ReprogramarCita')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF11 - Cancelar una cita con motivo y usuario
CREATE OR REPLACE PROCEDURE SP_CancelarCita(
      InUserName VARCHAR(100)
    , InIdCita INT
    , InMotivo VARCHAR(64)
    , InIdUsuario INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        UPDATE cita
        SET estado = 'cancelada', motivo_cancelada = InMotivo, id_usuario_cancelo = InIdUsuario
        WHERE id_clinica = app_id_clinica() AND id = InIdCita;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CancelarCita')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF12 - Registrar desenlace (atendida / ausente)
CREATE OR REPLACE PROCEDURE SP_RegistrarDesenlaceCita(
      InUserName VARCHAR(100)
    , InIdCita INT
    , InEstado VARCHAR(16)
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF InEstado IS NULL OR InEstado NOT IN ('atendida', 'ausente') THEN
            OutResult := 422;   -- el desenlace solo puede ser atendida o ausente
            RETURN;
        END IF;

        -- El trigger rechaza el cambio si aun no paso la hora de inicio (RF12)
        UPDATE cita SET estado = InEstado::estado_cita
        WHERE id_clinica = app_id_clinica() AND id = InIdCita;
        IF NOT FOUND THEN
            OutResult := 404;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_RegistrarDesenlaceCita')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF14 / RF18 - Registrar paciente (audita datos de contacto)
CREATE OR REPLACE PROCEDURE SP_CrearPaciente(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIp INET
    , InIdentificacion VARCHAR(16)
    , InNombre VARCHAR(32)
    , InFechaNacimiento DATE
    , InTelefono VARCHAR(20)
    , InCorreo VARCHAR(32)
    , OUT OutIdPaciente INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vCampos TEXT[];
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        INSERT INTO paciente (identificacion, nombre, fecha_nacimiento, telefono, correo)
        VALUES (InIdentificacion, InNombre, InFechaNacimiento, InTelefono, InCorreo)
        RETURNING id INTO OutIdPaciente;

        -- RF18: la escritura de datos de contacto queda en la bitacora
        vCampos := ARRAY_REMOVE(ARRAY[
            CASE WHEN InTelefono IS NOT NULL THEN 'telefono' END,
            CASE WHEN InCorreo   IS NOT NULL THEN 'correo'   END], NULL);
        IF CARDINALITY(vCampos) > 0 THEN
            INSERT INTO registro_auditoria (id_usuario, id_paciente, accion, info_usada, ip)
            VALUES (InIdUsuario, OutIdPaciente, 'escritura', ARRAY_TO_STRING(vCampos, ','), InIp);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdPaciente := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CrearPaciente')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF14 / RF18 - Actualizar paciente (audita datos de contacto)
CREATE OR REPLACE PROCEDURE SP_ActualizarPaciente(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIp INET
    , InIdPaciente INT
    , InIdentificacion VARCHAR(16)
    , InNombre VARCHAR(32)
    , InFechaNacimiento DATE
    , InTelefono VARCHAR(20)
    , InCorreo VARCHAR(32)
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vTelefonoAnterior VARCHAR(20);
    vCorreoAnterior VARCHAR(32);
    vCampos TEXT[];
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        SELECT p.telefono, p.correo INTO vTelefonoAnterior, vCorreoAnterior
        FROM paciente p
        WHERE p.id_clinica = app_id_clinica() AND p.id = InIdPaciente
        FOR UPDATE;
        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;

        UPDATE paciente
        SET identificacion = InIdentificacion, nombre = InNombre, fecha_nacimiento = InFechaNacimiento,
            telefono = InTelefono, correo = InCorreo
        WHERE id_clinica = app_id_clinica() AND id = InIdPaciente;

        -- RF18: se audita solo lo que cambio de los datos de contacto
        vCampos := ARRAY_REMOVE(ARRAY[
            CASE WHEN InTelefono IS DISTINCT FROM vTelefonoAnterior THEN 'telefono' END,
            CASE WHEN InCorreo   IS DISTINCT FROM vCorreoAnterior  THEN 'correo'   END], NULL);
        IF CARDINALITY(vCampos) > 0 THEN
            INSERT INTO registro_auditoria (id_usuario, id_paciente, accion, info_usada, ip)
            VALUES (InIdUsuario, InIdPaciente, 'escritura', ARRAY_TO_STRING(vCampos, ','), InIp);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ActualizarPaciente')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF14 / RF18 - Consultar un paciente con sus datos de contacto (cursor, audita lectura)
CREATE OR REPLACE PROCEDURE SP_ConsultarPaciente(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIp INET
    , InIdPaciente INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM paciente p WHERE p.id_clinica = app_id_clinica() AND p.id = InIdPaciente) THEN
            OutResult := 404;
            RETURN;
        END IF;

        -- RF18: la lectura de datos de contacto queda en la bitacora
        INSERT INTO registro_auditoria (id_usuario, id_paciente, accion, info_usada, ip)
        VALUES (InIdUsuario, InIdPaciente, 'lectura', 'telefono,correo', InIp);

        OPEN OutCursor FOR
            SELECT p.id, p.identificacion, p.nombre, p.fecha_nacimiento, p.telefono, p.correo
            FROM paciente p
            WHERE p.id_clinica = app_id_clinica() AND p.id = InIdPaciente;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ConsultarPaciente')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF14 - Buscar pacientes por identificacion o nombre (cursor)
CREATE OR REPLACE PROCEDURE SP_BuscarPacientes(
      InUserName VARCHAR(100)
    , InTexto VARCHAR(32)
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- No devuelve datos de contacto, por eso no genera registro de auditoria
        OPEN OutCursor FOR
            SELECT p.id, p.identificacion, p.nombre, p.fecha_nacimiento
            FROM paciente p
            WHERE p.id_clinica = app_id_clinica()
              AND (InTexto IS NULL OR InTexto = '' OR p.identificacion = InTexto OR p.nombre ILIKE '%' || InTexto || '%')
            ORDER BY p.nombre
            LIMIT 50;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_BuscarPacientes')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF15 / RF18 - Adjuntar nota clinica a una cita atendida
CREATE OR REPLACE PROCEDURE SP_CrearNotaClinica(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIp INET
    , InIdCita INT
    , InContenido TEXT
    , OUT OutIdNotaClinica INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vIdProfesional INT;
    vIdPaciente INT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- El profesional se resuelve desde el usuario autenticado: solo escribe quien atendio la cita
        SELECT pr.id INTO vIdProfesional
        FROM profesional pr
        WHERE pr.id_clinica = app_id_clinica() AND pr.id_usuario = InIdUsuario;
        IF NOT FOUND THEN
            OutResult := 403;
            RETURN;
        END IF;

        SELECT c.id_paciente INTO vIdPaciente
        FROM cita c
        WHERE c.id_clinica = app_id_clinica() AND c.id = InIdCita;
        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;

        -- Los triggers exigen cita atendida y que el profesional sea el de la cita
        INSERT INTO nota_clinica (id_cita, id_profesional, contenido)
        VALUES (InIdCita, vIdProfesional, InContenido)
        RETURNING id INTO OutIdNotaClinica;

        INSERT INTO registro_auditoria (id_usuario, id_paciente, id_nota_clinica, accion, info_usada, ip)
        VALUES (InIdUsuario, vIdPaciente, OutIdNotaClinica, 'escritura', 'contenido', InIp);
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdNotaClinica := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_CrearNotaClinica')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF15 / RF18 - Consultar la nota clinica de una cita propia (cursor, audita lectura)
CREATE OR REPLACE PROCEDURE SP_ConsultarNotaClinica(
      InUserName VARCHAR(100)
    , InIdUsuario INT
    , InIp INET
    , InIdCita INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vIdProfesional INT;
    vIdProfesionalNota INT;
    vIdNota INT;
    vIdPaciente INT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        SELECT pr.id INTO vIdProfesional
        FROM profesional pr
        WHERE pr.id_clinica = app_id_clinica() AND pr.id_usuario = InIdUsuario;
        IF NOT FOUND THEN
            OutResult := 403;
            RETURN;
        END IF;

        SELECT n.id, n.id_profesional, c.id_paciente
        INTO vIdNota, vIdProfesionalNota, vIdPaciente
        FROM nota_clinica n
        JOIN cita c ON c.id_clinica = n.id_clinica AND c.id = n.id_cita
        WHERE n.id_clinica = app_id_clinica() AND n.id_cita = InIdCita;
        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;
        IF vIdProfesionalNota <> vIdProfesional THEN
            OutResult := 403;   -- solo el profesional de la cita lee su nota
            RETURN;
        END IF;

        INSERT INTO registro_auditoria (id_usuario, id_paciente, id_nota_clinica, accion, info_usada, ip)
        VALUES (InIdUsuario, vIdPaciente, vIdNota, 'lectura', 'contenido', InIp);

        OPEN OutCursor FOR
            SELECT n.id, n.id_cita, n.id_profesional, n.contenido, n.fecha_creacion
            FROM nota_clinica n
            WHERE n.id_clinica = app_id_clinica() AND n.id = vIdNota;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ConsultarNotaClinica')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF16 - Historial de citas de un paciente con su estado (cursor)
CREATE OR REPLACE PROCEDURE SP_ConsultarHistorialPaciente(
      InUserName VARCHAR(100)
    , InIdPaciente INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM paciente p WHERE p.id_clinica = app_id_clinica() AND p.id = InIdPaciente) THEN
            OutResult := 404;
            RETURN;
        END IF;

        OPEN OutCursor FOR
            SELECT c.id AS id_cita, c.hora_inicio, c.hora_fin, c.estado, s.nombre AS servicio,
                   c.id_profesional, u.nombre_usuario AS profesional, c.motivo_cancelada
            FROM cita c
            JOIN servicio s ON s.id_clinica = c.id_clinica AND s.id = c.id_servicio
            JOIN profesional pr ON pr.id_clinica = c.id_clinica AND pr.id = c.id_profesional
            JOIN usuario u ON u.id_clinica = pr.id_clinica AND u.id = pr.id_usuario
            WHERE c.id_clinica = app_id_clinica() AND c.id_paciente = InIdPaciente
            ORDER BY c.hora_inicio DESC;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ConsultarHistorialPaciente')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF19 - Consultar la bitacora con filtros por usuario, paciente y rango de fechas (cursor)
CREATE OR REPLACE PROCEDURE SP_ConsultarAuditoria(
      InUserName VARCHAR(100)
    , InIdUsuarioFiltro INT
    , InIdPacienteFiltro INT
    , InFechaDesde TIMESTAMPTZ
    , InFechaHasta TIMESTAMPTZ
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- Filtros opcionales: un parametro NULL no filtra. Solo el administrador de clinica (lo valida el backend).
        OPEN OutCursor FOR
            SELECT a.id, a.id_usuario, u.nombre_usuario, a.id_paciente, p.nombre AS paciente,
                   a.id_nota_clinica, a.accion, a.info_usada, a.estampa_de_tiempo, a.ip
            FROM registro_auditoria a
            JOIN usuario u ON u.id_clinica = a.id_clinica AND u.id = a.id_usuario
            JOIN paciente p ON p.id_clinica = a.id_clinica AND p.id = a.id_paciente
            WHERE a.id_clinica = app_id_clinica()
              AND (InIdUsuarioFiltro  IS NULL OR a.id_usuario = InIdUsuarioFiltro)
              AND (InIdPacienteFiltro IS NULL OR a.id_paciente = InIdPacienteFiltro)
              AND (InFechaDesde IS NULL OR a.estampa_de_tiempo >= InFechaDesde)
              AND (InFechaHasta IS NULL OR a.estampa_de_tiempo <= InFechaHasta)
            ORDER BY a.estampa_de_tiempo DESC;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ConsultarAuditoria')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF20 - Agenda del dia de un profesional o de toda la clinica (cursor)
CREATE OR REPLACE PROCEDURE SP_ConsultarAgendaDia(
      InUserName VARCHAR(100)
    , InFecha DATE
    , InIdProfesional INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vZona VARCHAR(32);
    vInicio TIMESTAMPTZ;
    vFin TIMESTAMPTZ;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        -- InIdProfesional NULL = agenda de toda la clinica. El dia se interpreta en la zona horaria de la clinica.
        SELECT c.zona_horaria INTO vZona FROM clinica c WHERE c.id = app_id_clinica();
        vInicio := InFecha::TIMESTAMP AT TIME ZONE vZona;
        vFin    := (InFecha + 1)::TIMESTAMP AT TIME ZONE vZona;

        OPEN OutCursor FOR
            SELECT c.id AS id_cita, c.hora_inicio, c.hora_fin, c.estado,
                   c.id_paciente, p.nombre AS paciente,
                   c.id_servicio, s.nombre AS servicio,
                   c.id_profesional, u.nombre_usuario AS profesional
            FROM cita c
            JOIN paciente p ON p.id_clinica = c.id_clinica AND p.id = c.id_paciente
            JOIN servicio s ON s.id_clinica = c.id_clinica AND s.id = c.id_servicio
            JOIN profesional pr ON pr.id_clinica = c.id_clinica AND pr.id = c.id_profesional
            JOIN usuario u ON u.id_clinica = pr.id_clinica AND u.id = pr.id_usuario
            WHERE c.id_clinica = app_id_clinica()
              AND c.hora_inicio >= vInicio AND c.hora_inicio < vFin
              AND (InIdProfesional IS NULL OR c.id_profesional = InIdProfesional)
            ORDER BY c.hora_inicio, u.nombre_usuario;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ConsultarAgendaDia')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF21 - Conteo de citas por estado en un rango de fechas (cursor)
CREATE OR REPLACE PROCEDURE SP_ContarCitasPorEstado(
      InUserName VARCHAR(100)
    , InFechaDesde DATE
    , InFechaHasta DATE
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vZona VARCHAR(32);
    vInicio TIMESTAMPTZ;
    vFin TIMESTAMPTZ;
BEGIN
    OutResult := 0;

    -- Validaciones: el contexto del tenant debe estar definido
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    -- Equivalente a BEGIN TRANSACTION: el bloque con EXCEPTION abre un savepoint implicito
    -- (el COMMIT lo hace la transaccion del backend, para conservar el contexto del tenant)
    BEGIN
        IF InFechaDesde IS NULL OR InFechaHasta IS NULL OR InFechaHasta < InFechaDesde THEN
            OutResult := 422;
            RETURN;
        END IF;

        SELECT c.zona_horaria INTO vZona FROM clinica c WHERE c.id = app_id_clinica();
        vInicio := InFechaDesde::TIMESTAMP AT TIME ZONE vZona;
        vFin    := (InFechaHasta + 1)::TIMESTAMP AT TIME ZONE vZona;

        -- Devuelve todos los estados, incluso los que tienen 0 citas
        OPEN OutCursor FOR
            SELECT e.estado, COUNT(c.id) AS cantidad
            FROM UNNEST(ENUM_RANGE(NULL::estado_cita)) AS e(estado)
            LEFT JOIN cita c
                   ON c.estado = e.estado
                  AND c.id_clinica = app_id_clinica()
                  AND c.hora_inicio >= vInicio AND c.hora_inicio < vFin
            GROUP BY e.estado
            ORDER BY e.estado;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se deshace lo hecho dentro del bloque (rollback al savepoint implicito)
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;

            -- Codigo de salida segun el tipo de error
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409   -- solape, duplicado o deadlock (reintentar)
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;

            -- En caso de error, se guarda la informacion en db_error
            INSERT INTO db_error
            (
                user_name
                , error_number
                , error_state
                , error_severity
                , error_line
                , error_procedure
                , error_message
                , error_datetime
            )
            VALUES
            (
                InUserName
                , OutResult
                , vSqlState
                , 'ERROR'
                , NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT
                , COALESCE(SUBSTRING(vContext FROM '(?:function|procedure) ([A-Za-z0-9_]+)\('), 'SP_ContarCitasPorEstado')
                , vMessage
                , now()
            );
    END;
END;
$$;

-- RF17 - Resolver identidad del proveedor externo por token_sub
CREATE OR REPLACE PROCEDURE SP_ResolverIdentidad(
      InTokenSub VARCHAR(128)
    , OUT OutIdUsuario INT
    , OUT OutIdClinica INT
    , OUT OutIdRol INT
    , OUT OutNombreUsuario VARCHAR(128)
    , OUT OutCorreo VARCHAR(32)
    , OUT OutActivo BOOLEAN
    , OUT OutIdProfesional INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OutResult := 0;

    SELECT u.id, u.id_clinica, u.id_rol, u.nombre_usuario, u.correo, u.activo
    INTO OutIdUsuario, OutIdClinica, OutIdRol, OutNombreUsuario, OutCorreo, OutActivo
    FROM usuario u
    WHERE u.token_sub = InTokenSub;

    IF NOT FOUND THEN
        OutResult := 403;
        RETURN;
    END IF;

    IF OutIdClinica IS NOT NULL THEN
        PERFORM set_config('app.id_clinica', OutIdClinica::TEXT, TRUE);
        SELECT p.id INTO OutIdProfesional
        FROM profesional p
        WHERE p.id_clinica = OutIdClinica AND p.id_usuario = OutIdUsuario;
    END IF;
END;
$$;

-- Auxiliar RF3 / RF4 - Resolver o crear especialidad en el catalogo global
CREATE OR REPLACE PROCEDURE SP_ResolverEspecialidad(
      InUserName VARCHAR(100)
    , InNombre VARCHAR(32)
    , OUT OutIdEspecialidad INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
BEGIN
    OutResult := 0;

    BEGIN
        SELECT e.id INTO OutIdEspecialidad
        FROM especialidad e
        WHERE LOWER(e.nombre) = LOWER(TRIM(InNombre));

        IF NOT FOUND THEN
            INSERT INTO especialidad (nombre, descripcion)
            VALUES (LEFT(TRIM(InNombre), 32), LEFT(TRIM(InNombre), 64))
            RETURNING id INTO OutIdEspecialidad;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutIdEspecialidad := NULL;
            INSERT INTO db_error (user_name, error_number, error_state, error_severity, error_line, error_procedure, error_message, error_datetime)
            VALUES (InUserName, OutResult, vSqlState, 'ERROR', NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT, 'SP_ResolverEspecialidad', vMessage, now());
    END;
END;
$$;

-- RF7 - Calcular espacios disponibles de un profesional en una fecha (en caso de cache miss en Redis)
CREATE OR REPLACE PROCEDURE SP_ConsultarDisponibilidadProfesional(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , InIdServicio INT
    , InFecha DATE
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    vSqlState TEXT;
    vMessage  TEXT;
    vContext  TEXT;
    vDuracion INT;
    vZona VARCHAR(32);
BEGIN
    OutResult := 0;

    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;

    BEGIN
        IF InFecha IS NULL THEN
            OutResult := 422;
            RETURN;
        END IF;

        SELECT s.duracion_min, c.zona_horaria
        INTO vDuracion, vZona
        FROM servicio s
        JOIN clinica c ON c.id = s.id_clinica
        JOIN profesional_x_servicio x ON x.id_clinica = s.id_clinica AND x.id_servicio = s.id
        JOIN profesional p ON p.id_clinica = x.id_clinica AND p.id = x.id_profesional
        JOIN usuario u ON u.id_clinica = p.id_clinica AND u.id = p.id_usuario
        WHERE s.id_clinica = app_id_clinica()
          AND s.id = InIdServicio
          AND p.id = InIdProfesional
          AND u.activo;

        IF NOT FOUND THEN
            OutResult := 404;
            RETURN;
        END IF;

        OPEN OutCursor FOR
            WITH espacios AS (
                SELECT (InFecha + g.t) AT TIME ZONE vZona AS hora_inicio,
                       ((InFecha + g.t) AT TIME ZONE vZona) + make_interval(mins => vDuracion) AS hora_fin
                FROM horario_atencion h
                CROSS JOIN LATERAL generate_series(
                    h.hora_inicio,
                    h.hora_fin - make_interval(mins => vDuracion),
                    make_interval(mins => vDuracion)) AS g(t)
                WHERE h.id_clinica = app_id_clinica()
                  AND h.id_profesional = InIdProfesional
                  AND h.dia = EXTRACT(ISODOW FROM InFecha)::INT
            )
            SELECT e.hora_inicio, e.hora_fin
            FROM espacios e
            WHERE e.hora_inicio > now()
              AND NOT EXISTS (
                  SELECT 1 FROM cita c
                  WHERE c.id_clinica = app_id_clinica()
                    AND c.id_profesional = InIdProfesional
                    AND c.estado IN ('reservada', 'atendida')
                    AND tstzrange(c.hora_inicio, c.hora_fin) && tstzrange(e.hora_inicio, e.hora_fin))
              AND NOT EXISTS (
                  SELECT 1 FROM bloqueo_agenda b
                  WHERE b.id_clinica = app_id_clinica()
                    AND b.id_profesional = InIdProfesional
                    AND (b.id_servicio IS NULL OR b.id_servicio = InIdServicio)
                    AND tstzrange(b.hora_inicio, b.hora_fin) && tstzrange(e.hora_inicio, e.hora_fin))
            ORDER BY e.hora_inicio;
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                vSqlState = RETURNED_SQLSTATE,
                vMessage  = MESSAGE_TEXT,
                vContext  = PG_EXCEPTION_CONTEXT;
            OutResult := CASE
                WHEN vSqlState IN ('23P01', '23505', '40001', '40P01') THEN 409
                WHEN vSqlState IN ('23514', '23503', '23502') OR vSqlState LIKE '22%' THEN 422
                WHEN vSqlState = '42501' THEN 403
                WHEN vSqlState = 'P0002' THEN 404
                ELSE 500
            END;
            OutCursor := NULL;
            INSERT INTO db_error (user_name, error_number, error_state, error_severity, error_line, error_procedure, error_message, error_datetime)
            VALUES (InUserName, OutResult, vSqlState, 'ERROR', NULLIF(SUBSTRING(vContext FROM 'line ([0-9]+)'), '')::INT, 'SP_ConsultarDisponibilidadProfesional', vMessage, now());
    END;
END;
$$;

-- RF2 - Listar usuarios de la clinica (cursor)
CREATE OR REPLACE PROCEDURE SP_ListarUsuarios(
      InUserName VARCHAR(100)
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    OPEN OutCursor FOR
        SELECT u.id, u.id_clinica, u.id_rol, r.nombre AS rol_nombre, u.nombre_usuario, u.correo, u.token_sub, u.activo
        FROM usuario u
        JOIN rol r ON r.id = u.id_rol
        WHERE u.id_clinica = app_id_clinica()
        ORDER BY u.id;
END;
$$;

-- RF3 - Listar servicios del catalogo de la clinica (cursor)
CREATE OR REPLACE PROCEDURE SP_ListarServicios(
      InUserName VARCHAR(100)
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    OPEN OutCursor FOR
        SELECT s.id, s.id_clinica, s.id_especialidad, e.nombre AS especialidad, s.nombre, s.duracion_min
        FROM servicio s
        JOIN especialidad e ON e.id = s.id_especialidad
        WHERE s.id_clinica = app_id_clinica()
        ORDER BY s.id;
END;
$$;

-- RF4 - Listar profesionales de la clinica (cursor)
CREATE OR REPLACE PROCEDURE SP_ListarProfesionales(
      InUserName VARCHAR(100)
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    OPEN OutCursor FOR
        SELECT p.id, p.id_clinica, p.id_usuario, u.nombre_usuario AS nombre, p.id_especialidad, e.nombre AS especialidad, u.activo
        FROM profesional p
        JOIN usuario u ON u.id_clinica = p.id_clinica AND u.id = p.id_usuario
        JOIN especialidad e ON e.id = p.id_especialidad
        WHERE p.id_clinica = app_id_clinica()
        ORDER BY p.id;
END;
$$;

-- RF5 - Listar horarios semanales de un profesional (cursor)
CREATE OR REPLACE PROCEDURE SP_ListarHorariosProfesional(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    OPEN OutCursor FOR
        SELECT h.id, h.id_clinica, h.id_profesional, h.dia, h.hora_inicio, h.hora_fin
        FROM horario_atencion h
        WHERE h.id_clinica = app_id_clinica() AND h.id_profesional = InIdProfesional
        ORDER BY h.dia, h.hora_inicio;
END;
$$;

-- RF6 - Listar bloqueos de agenda de un profesional (cursor)
CREATE OR REPLACE PROCEDURE SP_ListarBloqueosProfesional(
      InUserName VARCHAR(100)
    , InIdProfesional INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    OPEN OutCursor FOR
        SELECT b.id, b.id_clinica, b.id_profesional, b.id_servicio, b.id_usuario, b.hora_inicio, b.hora_fin, b.motivo
        FROM bloqueo_agenda b
        WHERE b.id_clinica = app_id_clinica() AND b.id_profesional = InIdProfesional
        ORDER BY b.hora_inicio;
END;
$$;

-- RF6 - Eliminar un bloqueo de agenda
CREATE OR REPLACE PROCEDURE SP_EliminarBloqueoAgenda(
      InUserName VARCHAR(100)
    , InIdBloqueo INT
    , OUT OutIdProfesional INT
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    DELETE FROM bloqueo_agenda
    WHERE id_clinica = app_id_clinica() AND id = InIdBloqueo
    RETURNING id_profesional INTO OutIdProfesional;
    IF NOT FOUND THEN
        OutResult := 404;
    END IF;
END;
$$;

-- RF9..RF13 - Consultar una cita por identificador (cursor)
CREATE OR REPLACE PROCEDURE SP_ConsultarCita(
      InUserName VARCHAR(100)
    , InIdCita INT
    , OUT OutCursor REFCURSOR
    , OUT OutResult INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    OutResult := 0;
    IF app_id_clinica() IS NULL THEN
        OutResult := 403;
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cita c WHERE c.id_clinica = app_id_clinica() AND c.id = InIdCita) THEN
        OutResult := 404;
        RETURN;
    END IF;
    OPEN OutCursor FOR
        SELECT c.id, c.id_clinica, c.id_cita_origen, c.id_paciente, c.id_profesional, c.id_servicio,
               c.id_usuario_cancelo, c.creada, c.estado, c.hora_inicio, c.hora_fin, c.motivo_cancelada
        FROM cita c
        WHERE c.id_clinica = app_id_clinica() AND c.id = InIdCita;
END;
$$;

-- ---------------------------------------------------------------------
-- Privilegios de ejecucion: cada rol solo ejecuta sus procedimientos
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;

-- Identidad (todos los perfiles autenticados)
GRANT EXECUTE ON PROCEDURE SP_ResolverIdentidad(VARCHAR(128)) TO app_plataforma, app_medicitas, app_admin_clinica, app_recepcion, app_profesional;

-- Plataforma (RF1)
GRANT EXECUTE ON PROCEDURE SP_AltaClinica(VARCHAR(100), VARCHAR(32), VARCHAR(32), VARCHAR(32), VARCHAR(128), VARCHAR(32), VARCHAR(128)) TO app_plataforma;

-- Administracion de clinica: usuarios, servicios y profesionales (RF2 a RF4)
GRANT EXECUTE ON PROCEDURE SP_CrearUsuario(VARCHAR(100), VARCHAR(128), VARCHAR(32), VARCHAR(128), INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_CambiarRolUsuario(VARCHAR(100), INT, INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_DarBajaUsuario(VARCHAR(100), INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_ListarUsuarios(VARCHAR(100)) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_ResolverEspecialidad(VARCHAR(100), VARCHAR(32)) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_CrearServicio(VARCHAR(100), VARCHAR(16), INT, INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_ActualizarServicio(VARCHAR(100), INT, VARCHAR(16), INT, INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_ListarServicios(VARCHAR(100)) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_CrearProfesional(VARCHAR(100), INT, INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_AsignarServicioProfesional(VARCHAR(100), INT, INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_QuitarServicioProfesional(VARCHAR(100), INT, INT) TO app_admin_clinica;
GRANT EXECUTE ON PROCEDURE SP_ListarProfesionales(VARCHAR(100)) TO app_admin_clinica, app_recepcion, app_profesional;

-- Horarios y bloqueos (RF5, RF6): admin de clinica y profesional
GRANT EXECUTE ON PROCEDURE SP_AgregarHorarioAtencion(VARCHAR(100), INT, INT, TIME, TIME) TO app_admin_clinica, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_EliminarHorarioAtencion(VARCHAR(100), INT) TO app_admin_clinica, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ListarHorariosProfesional(VARCHAR(100), INT) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_RegistrarBloqueoAgenda(VARCHAR(100), INT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, VARCHAR(16)) TO app_admin_clinica, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ListarConflictosBloqueo(VARCHAR(100), INT) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ListarBloqueosProfesional(VARCHAR(100), INT) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_EliminarBloqueoAgenda(VARCHAR(100), INT) TO app_admin_clinica, app_profesional;

-- Disponibilidad (RF7, RF8): admin de clinica, recepcion y profesional
GRANT EXECUTE ON PROCEDURE SP_ConsultarDisponibilidadProfesional(VARCHAR(100), INT, INT, DATE) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ConsultarDisponibilidadServicio(VARCHAR(100), INT, DATE, DATE) TO app_admin_clinica, app_recepcion, app_profesional;

-- Reservar, reprogramar y cancelar citas (RF9 a RF11): admin de clinica y recepcion
GRANT EXECUTE ON PROCEDURE SP_ReservarCita(VARCHAR(100), INT, INT, INT, TIMESTAMPTZ) TO app_admin_clinica, app_recepcion;
GRANT EXECUTE ON PROCEDURE SP_ReprogramarCita(VARCHAR(100), INT, TIMESTAMPTZ, INT) TO app_admin_clinica, app_recepcion;
GRANT EXECUTE ON PROCEDURE SP_CancelarCita(VARCHAR(100), INT, VARCHAR(64), INT) TO app_admin_clinica, app_recepcion;

-- Desenlace y consulta de cita (RF12, RF13): admin de clinica, recepcion y profesional
GRANT EXECUTE ON PROCEDURE SP_RegistrarDesenlaceCita(VARCHAR(100), INT, VARCHAR(16)) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ConsultarCita(VARCHAR(100), INT) TO app_admin_clinica, app_recepcion, app_profesional;

-- Pacientes e historial (RF14, RF16): escritura solo admin y recepcion; lectura/historial tambien profesional
GRANT EXECUTE ON PROCEDURE SP_CrearPaciente(VARCHAR(100), INT, INET, VARCHAR(16), VARCHAR(32), DATE, VARCHAR(20), VARCHAR(32)) TO app_admin_clinica, app_recepcion;
GRANT EXECUTE ON PROCEDURE SP_ActualizarPaciente(VARCHAR(100), INT, INET, INT, VARCHAR(16), VARCHAR(32), DATE, VARCHAR(20), VARCHAR(32)) TO app_admin_clinica, app_recepcion;
GRANT EXECUTE ON PROCEDURE SP_ConsultarPaciente(VARCHAR(100), INT, INET, INT) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_BuscarPacientes(VARCHAR(100), VARCHAR(32)) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ConsultarHistorialPaciente(VARCHAR(100), INT) TO app_admin_clinica, app_recepcion, app_profesional;

-- Notas clinicas (RF15): EXCLUSIVO del profesional
GRANT EXECUTE ON PROCEDURE SP_CrearNotaClinica(VARCHAR(100), INT, INET, INT, TEXT) TO app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ConsultarNotaClinica(VARCHAR(100), INT, INET, INT) TO app_profesional;

-- Bitacora de auditoria (RF19): EXCLUSIVO del administrador de clinica
GRANT EXECUTE ON PROCEDURE SP_ConsultarAuditoria(VARCHAR(100), INT, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO app_admin_clinica;

-- Agenda y estadisticas (RF20, RF21)
GRANT EXECUTE ON PROCEDURE SP_ConsultarAgendaDia(VARCHAR(100), DATE, INT) TO app_admin_clinica, app_recepcion, app_profesional;
GRANT EXECUTE ON PROCEDURE SP_ContarCitasPorEstado(VARCHAR(100), DATE, DATE) TO app_admin_clinica, app_recepcion;