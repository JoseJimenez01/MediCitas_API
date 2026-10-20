INSERT INTO med.usuarios(id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000001', 'Administracion de plataforma', 'platform-admin') ON CONFLICT DO NOTHING;
INSERT INTO med.clinicas(id, identificador, nombre, zona_horaria) VALUES ('10000000-0000-0000-0000-000000000001', 'CLINICA-1', 'Cartago Centro', 'America/Costa_Rica') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', 'Administracion 1', 'clinic-admin') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', 'Recepcion 1', 'reception') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000001', 'Dra. Sofia 1', 'professional') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000104', '10000000-0000-0000-0000-000000000001', 'Dr. Daniel 1', 'professional') ON CONFLICT DO NOTHING;
INSERT INTO med.especialidades(id, clinica_id, nombre) VALUES ('60000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', 'Medicina general') ON CONFLICT DO NOTHING;
INSERT INTO med.servicios(id, clinica_id, nombre, duracion_minutos, especialidad_id) VALUES ('40000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', 'Consulta general', 30, '60000000-0000-0000-0000-000000000101') ON CONFLICT DO NOTHING;
INSERT INTO med.servicios(id, clinica_id, nombre, duracion_minutos, especialidad_id) VALUES ('40000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', 'Valoracion completa', 60, '60000000-0000-0000-0000-000000000101') ON CONFLICT DO NOTHING;
INSERT INTO med.profesionales(id, clinica_id, usuario_id, especialidad_id, nombre) VALUES ('30000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000103', '60000000-0000-0000-0000-000000000101', 'Dra. Sofia 1') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000101', '40000000-0000-0000-0000-000000000101') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000101', '40000000-0000-0000-0000-000000000102') ON CONFLICT DO NOTHING;
INSERT INTO med.horarios(id, clinica_id, profesional_id, dia_semana, inicio, fin)
SELECT md5('10000000-0000-0000-0000-000000000001-1-' || d || '-' || b)::uuid, '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000101', d,
CASE b WHEN 1 THEN time '08:00' ELSE time '13:00' END, CASE b WHEN 1 THEN time '12:00' ELSE time '17:00' END
FROM generate_series(1,7) d CROSS JOIN generate_series(1,2) b ON CONFLICT DO NOTHING;
INSERT INTO med.pacientes(id, clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES ('50000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', '1-000-1', 'Ana Mora 1', '1997-04-12', 'paciente11@example.test') ON CONFLICT DO NOTHING;
INSERT INTO med.profesionales(id, clinica_id, usuario_id, especialidad_id, nombre) VALUES ('30000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000104', '60000000-0000-0000-0000-000000000101', 'Dr. Daniel 1') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000102', '40000000-0000-0000-0000-000000000101') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000102', '40000000-0000-0000-0000-000000000102') ON CONFLICT DO NOTHING;
INSERT INTO med.horarios(id, clinica_id, profesional_id, dia_semana, inicio, fin)
SELECT md5('10000000-0000-0000-0000-000000000001-2-' || d || '-' || b)::uuid, '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000102', d,
CASE b WHEN 1 THEN time '08:00' ELSE time '13:00' END, CASE b WHEN 1 THEN time '12:00' ELSE time '17:00' END
FROM generate_series(1,7) d CROSS JOIN generate_series(1,2) b ON CONFLICT DO NOTHING;
INSERT INTO med.pacientes(id, clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES ('50000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', '1-000-2', 'Luis Vargas 1', '1984-08-20', 'paciente12@example.test') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000101', '30000000-0000-0000-0000-000000000101', '40000000-0000-0000-0000-000000000101',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '2 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '2 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'atendida', '20000000-0000-0000-0000-000000000102') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000101', '30000000-0000-0000-0000-000000000101', '40000000-0000-0000-0000-000000000101',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '3 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '3 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'ausente', '20000000-0000-0000-0000-000000000102') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000101', '30000000-0000-0000-0000-000000000101', '40000000-0000-0000-0000-000000000101',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '4 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '4 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'cancelada', '20000000-0000-0000-0000-000000000102') ON CONFLICT DO NOTHING;
INSERT INTO med.clinicas(id, identificador, nombre, zona_horaria) VALUES ('10000000-0000-0000-0000-000000000002', 'CLINICA-2', 'Limon Caribe', 'America/Costa_Rica') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', 'Administracion 2', 'clinic-admin') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000002', 'Recepcion 2', 'reception') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000203', '10000000-0000-0000-0000-000000000002', 'Dra. Sofia 2', 'professional') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000204', '10000000-0000-0000-0000-000000000002', 'Dr. Daniel 2', 'professional') ON CONFLICT DO NOTHING;
INSERT INTO med.especialidades(id, clinica_id, nombre) VALUES ('60000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', 'Medicina general') ON CONFLICT DO NOTHING;
INSERT INTO med.servicios(id, clinica_id, nombre, duracion_minutos, especialidad_id) VALUES ('40000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', 'Consulta general', 30, '60000000-0000-0000-0000-000000000201') ON CONFLICT DO NOTHING;
INSERT INTO med.servicios(id, clinica_id, nombre, duracion_minutos, especialidad_id) VALUES ('40000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000002', 'Valoracion completa', 60, '60000000-0000-0000-0000-000000000201') ON CONFLICT DO NOTHING;
INSERT INTO med.profesionales(id, clinica_id, usuario_id, especialidad_id, nombre) VALUES ('30000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000203', '60000000-0000-0000-0000-000000000201', 'Dra. Sofia 2') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000201', '40000000-0000-0000-0000-000000000201') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000201', '40000000-0000-0000-0000-000000000202') ON CONFLICT DO NOTHING;
INSERT INTO med.horarios(id, clinica_id, profesional_id, dia_semana, inicio, fin)
SELECT md5('10000000-0000-0000-0000-000000000002-1-' || d || '-' || b)::uuid, '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000201', d,
CASE b WHEN 1 THEN time '08:00' ELSE time '13:00' END, CASE b WHEN 1 THEN time '12:00' ELSE time '17:00' END
FROM generate_series(1,7) d CROSS JOIN generate_series(1,2) b ON CONFLICT DO NOTHING;
INSERT INTO med.pacientes(id, clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES ('50000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', '2-000-1', 'Ana Mora 2', '1997-04-12', 'paciente21@example.test') ON CONFLICT DO NOTHING;
INSERT INTO med.profesionales(id, clinica_id, usuario_id, especialidad_id, nombre) VALUES ('30000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000204', '60000000-0000-0000-0000-000000000201', 'Dr. Daniel 2') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000202', '40000000-0000-0000-0000-000000000201') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000202', '40000000-0000-0000-0000-000000000202') ON CONFLICT DO NOTHING;
INSERT INTO med.horarios(id, clinica_id, profesional_id, dia_semana, inicio, fin)
SELECT md5('10000000-0000-0000-0000-000000000002-2-' || d || '-' || b)::uuid, '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000202', d,
CASE b WHEN 1 THEN time '08:00' ELSE time '13:00' END, CASE b WHEN 1 THEN time '12:00' ELSE time '17:00' END
FROM generate_series(1,7) d CROSS JOIN generate_series(1,2) b ON CONFLICT DO NOTHING;
INSERT INTO med.pacientes(id, clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES ('50000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000002', '2-000-2', 'Luis Vargas 2', '1984-08-20', 'paciente22@example.test') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000201', '30000000-0000-0000-0000-000000000201', '40000000-0000-0000-0000-000000000201',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '2 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '2 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'atendida', '20000000-0000-0000-0000-000000000202') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000201', '30000000-0000-0000-0000-000000000201', '40000000-0000-0000-0000-000000000201',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '3 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '3 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'ausente', '20000000-0000-0000-0000-000000000202') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000203', '10000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000201', '30000000-0000-0000-0000-000000000201', '40000000-0000-0000-0000-000000000201',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '4 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '4 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'cancelada', '20000000-0000-0000-0000-000000000202') ON CONFLICT DO NOTHING;
INSERT INTO med.clinicas(id, identificador, nombre, zona_horaria) VALUES ('10000000-0000-0000-0000-000000000003', 'CLINICA-3', 'San Jose Norte', 'America/Costa_Rica') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', 'Administracion 3', 'clinic-admin') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000302', '10000000-0000-0000-0000-000000000003', 'Recepcion 3', 'reception') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000303', '10000000-0000-0000-0000-000000000003', 'Dra. Sofia 3', 'professional') ON CONFLICT DO NOTHING;
INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES ('20000000-0000-0000-0000-000000000304', '10000000-0000-0000-0000-000000000003', 'Dr. Daniel 3', 'professional') ON CONFLICT DO NOTHING;
INSERT INTO med.especialidades(id, clinica_id, nombre) VALUES ('60000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', 'Medicina general') ON CONFLICT DO NOTHING;
INSERT INTO med.servicios(id, clinica_id, nombre, duracion_minutos, especialidad_id) VALUES ('40000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', 'Consulta general', 30, '60000000-0000-0000-0000-000000000301') ON CONFLICT DO NOTHING;
INSERT INTO med.servicios(id, clinica_id, nombre, duracion_minutos, especialidad_id) VALUES ('40000000-0000-0000-0000-000000000302', '10000000-0000-0000-0000-000000000003', 'Valoracion completa', 60, '60000000-0000-0000-0000-000000000301') ON CONFLICT DO NOTHING;
INSERT INTO med.profesionales(id, clinica_id, usuario_id, especialidad_id, nombre) VALUES ('30000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000303', '60000000-0000-0000-0000-000000000301', 'Dra. Sofia 3') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000301', '40000000-0000-0000-0000-000000000301') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000301', '40000000-0000-0000-0000-000000000302') ON CONFLICT DO NOTHING;
INSERT INTO med.horarios(id, clinica_id, profesional_id, dia_semana, inicio, fin)
SELECT md5('10000000-0000-0000-0000-000000000003-1-' || d || '-' || b)::uuid, '10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000301', d,
CASE b WHEN 1 THEN time '08:00' ELSE time '13:00' END, CASE b WHEN 1 THEN time '12:00' ELSE time '17:00' END
FROM generate_series(1,7) d CROSS JOIN generate_series(1,2) b ON CONFLICT DO NOTHING;
INSERT INTO med.pacientes(id, clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES ('50000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', '3-000-1', 'Ana Mora 3', '1997-04-12', 'paciente31@example.test') ON CONFLICT DO NOTHING;
INSERT INTO med.profesionales(id, clinica_id, usuario_id, especialidad_id, nombre) VALUES ('30000000-0000-0000-0000-000000000302', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000304', '60000000-0000-0000-0000-000000000301', 'Dr. Daniel 3') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000302', '40000000-0000-0000-0000-000000000301') ON CONFLICT DO NOTHING;
INSERT INTO med.profesional_servicios VALUES ('10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000302', '40000000-0000-0000-0000-000000000302') ON CONFLICT DO NOTHING;
INSERT INTO med.horarios(id, clinica_id, profesional_id, dia_semana, inicio, fin)
SELECT md5('10000000-0000-0000-0000-000000000003-2-' || d || '-' || b)::uuid, '10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000302', d,
CASE b WHEN 1 THEN time '08:00' ELSE time '13:00' END, CASE b WHEN 1 THEN time '12:00' ELSE time '17:00' END
FROM generate_series(1,7) d CROSS JOIN generate_series(1,2) b ON CONFLICT DO NOTHING;
INSERT INTO med.pacientes(id, clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES ('50000000-0000-0000-0000-000000000302', '10000000-0000-0000-0000-000000000003', '3-000-2', 'Luis Vargas 3', '1984-08-20', 'paciente32@example.test') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000301', '30000000-0000-0000-0000-000000000301', '40000000-0000-0000-0000-000000000301',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '2 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '2 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'atendida', '20000000-0000-0000-0000-000000000302') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000302', '10000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000301', '30000000-0000-0000-0000-000000000301', '40000000-0000-0000-0000-000000000301',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '3 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '3 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'ausente', '20000000-0000-0000-0000-000000000302') ON CONFLICT DO NOTHING;
INSERT INTO med.citas(id, clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, estado, usuario_modificacion)
VALUES ('70000000-0000-0000-0000-000000000303', '10000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000301', '30000000-0000-0000-0000-000000000301', '40000000-0000-0000-0000-000000000301',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '4 days' + interval '9 hours') AT TIME ZONE 'America/Costa_Rica',
(date_trunc('day', now() AT TIME ZONE 'America/Costa_Rica') - interval '4 days' + interval '9 hours 30 minutes') AT TIME ZONE 'America/Costa_Rica', 'cancelada', '20000000-0000-0000-0000-000000000302') ON CONFLICT DO NOTHING;
