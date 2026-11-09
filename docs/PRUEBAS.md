# Informe de Pruebas — MediCitas

Resumen de las **33 pruebas automatizadas** en `Project_Restaurant_API.Tests` y su trazabilidad a los requisitos funcionales (`RF1`–`RF21`) e invariantes (`I1`–`I8`).

---

## 1. Cómo ejecutar las pruebas

Con la pila arriba (`docker compose up -d --build`):

```bash
docker build --target tests -t medicitas-tests . && docker run --rm --network host medicitas-tests
```

Resultado esperado:
```text
Passed!  - Failed:     0, Passed:    33, Skipped:     0, Total:    33 - Project_Restaurant_API.Tests.dll (net8.0)
```

---

## 2. Trazabilidad a Requisitos Funcionales (`RF1`–`RF21`)

| RF | Descripción | Prueba automatizada |
|---|---|---|
| **RF1** | Alta de clínica y su administrador inicial | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF2** | Gestión de usuarios, cambio de rol y desactivación | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta`, `KeycloakDirectoryTests` |
| **RF3** | Crear y actualizar servicios de la clínica | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta`, `EntradasDTO_ValidanRestriccionesDeDominio` |
| **RF4** | Gestión de profesionales y servicios habilitados | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF5** | Definir y eliminar bloques de horario semanal | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF6** | Registrar bloqueos de agenda y listar citas en conflicto | `RF6_I3_BloqueoRetiraEspaciosYListaConflictos` |
| **RF7** | Consultar disponibilidad de un profesional (con caché Redis) | `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes` |
| **RF8** | Buscar disponibilidad de un servicio en un rango de fechas | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF9** | Reservar una cita validando horario, bloqueos y solapes | `RF9_I1_CarreraTieneExactamenteUnaGanadora`, `RF9_I2_PacienteNoPuedeReservarDosProfesionalesAlMismoTiempo` |
| **RF10** | Reprogramar una cita de forma atómica | `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes`, `RF10_ReprogramacionFallidaConservaLaReservaOriginal` |
| **RF11** | Cancelar una cita registrando motivo y usuario | `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes` |
| **RF12** | Registrar desenlace (`atendida` / `ausente`) tras la hora de inicio | `RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos` |
| **RF13** | Estados finales no admiten cambios | `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes`, `RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos` |
| **RF14** | Gestión de pacientes, búsqueda e historial de citas | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF15** | Crear y consultar nota clínica (solo el profesional de la cita) | `RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos` |
| **RF16** | Consultar la agenda del día | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF17** | Validación de token y permisos por rol (`401` / `403`) | `RF17_SinToken401_RolInadecuado403`, `RF17_RolInadecuadoDevuelve403AunqueElCuerpoSeaInvalido`, `MedicalSecurityTests` |
| **RF18** | Auditoría de lecturas y escrituras de contacto y notas | `RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos` |
| **RF19** | Consulta de bitácora de auditoría con filtros | `RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos` |
| **RF20** | Conteo de citas por estado en un rango de fechas | `RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta` |
| **RF21** | Aislamiento multi-clínica | `I5_ParametrosYReferenciasNoPermitenFugaEntreClinicas`, `I5_I6_ModuloAdicional_RLSYBitacoraInmutable` |

---

## 3. Trazabilidad a Invariantes (`I1`–`I8`)

| Invariante | Qué garantiza | Prueba que lo verifica |
|---|---|---|
| **I1** | Sin solapes de citas vigentes para un mismo profesional | `RF9_I1_CarreraTieneExactamenteUnaGanadora` (dos peticiones simultáneas al mismo espacio: una devuelve `201` y la otra `409`). |
| **I2** | Sin solapes de citas vigentes para un mismo paciente | `RF9_I2_PacienteNoPuedeReservarDosProfesionalesAlMismoTiempo` (dos peticiones simultáneas con distintos profesionales: una `201` y una `409`). |
| **I3** | Sin reservas fuera del horario o dentro de un bloqueo | `RF6_I3_BloqueoRetiraEspaciosYListaConflictos` (rechaza reservas fuera de horario y dentro de rangos bloqueados con `400`). |
| **I4** | Duración de la cita calculada según el servicio | `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes` (`horaFin - horaInicio == 30 min`). |
| **I5** | Aislamiento total entre clínicas (API y RLS en base de datos) | `I5_ParametrosYReferenciasNoPermitenFugaEntreClinicas` e `I5_I6_ModuloAdicional_RLSYBitacoraInmutable`. |
| **I6** | Bitácora de auditoría `append-only` | `I5_I6_ModuloAdicional_RLSYBitacoraInmutable` (`UPDATE`, `DELETE` y `TRUNCATE` fallan con `SQLSTATE 42501`). |
| **I7** | PostgreSQL es la única fuente de verdad al reservar | `RF9_I1_CarreraTieneExactamenteUnaGanadora`, `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes`. |
| **I8** | Invalidación inmediata de la caché al cambiar la disponibilidad | `RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes` (verifica `cacheHit` y actualización inmediata tras reservar, reprogramar y cancelar). |
