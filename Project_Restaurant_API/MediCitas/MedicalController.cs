using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Project_Restaurant_API.MediCitas;

[ApiController]
[Authorize]
[Route("api")]
[ProducesResponseType(400)]
[ProducesResponseType(401)]
[ProducesResponseType(403)]
[ProducesResponseType(404)]
[ProducesResponseType(409)]
[ProducesResponseType(503)]
public sealed class MedicalController(MedicalDatabase database, Availability availability, KeycloakDirectory directory) : ControllerBase
{
    private async Task<MedicalSession> Open(CancellationToken ct, string[] roles, bool auditor = false)
    {
        var identity = await database.ResolveAsync(User, ct);
        if (!roles.Contains(identity.Rol)) throw new DomainException(403, "Operacion no permitida para este rol.");
        foreach (var key in new[] { "clinicaId", "clinica_id", "tenantId", "tenant_id" })
            if (Request.Query.TryGetValue(key, out var value) && value != identity.ClinicaId?.ToString())
                throw new DomainException(403, "La clinica se obtiene de la identidad.");
        return await database.OpenAsync(identity, ct, auditor);
    }

    private static readonly string[] ClinicRoles = ["clinic-admin", "reception", "professional"];
    private static readonly string[] ReceptionRoles = ["clinic-admin", "reception"];
    private static readonly string[] AdminRoles = ["clinic-admin"];

    private static void OwnProfessional(MedicalSession session, Guid professional)
    {
        if (session.Identity.Rol == "professional" && session.Identity.ProfesionalId != professional)
            throw new DomainException(403, "Solo puede operar sobre su propia agenda.");
    }

    private static async Task<Guid> Specialty(MedicalSession session, string name, CancellationToken ct)
    {
        var row = await session.OneAsync("""
            INSERT INTO med.especialidades(clinica_id, nombre) VALUES (@tenant, @name)
            ON CONFLICT (clinica_id, nombre) DO UPDATE SET nombre = EXCLUDED.nombre RETURNING id
            """, ct, ("tenant", session.Identity.ClinicaId), ("name", name.Trim()));
        return (Guid)row["id"]!;
    }

    [HttpGet("yo")]
    [ProducesResponseType(200)]
    public async Task<IActionResult> Me(CancellationToken ct) => Ok(await database.ResolveAsync(User, ct));

    [HttpPost("clinicas")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "platform-admin")]
    public async Task<IActionResult> CreateClinic(ClinicaInput input, CancellationToken ct)
    {
        var identity = await database.ResolveAsync(User, ct);
        if (identity.Rol != "platform-admin") throw new DomainException(403, "Solo administracion de plataforma.");
        try { _ = TimeZoneInfo.FindSystemTimeZoneById(input.ZonaHoraria); }
        catch (TimeZoneNotFoundException) { throw new DomainException(400, "Zona horaria invalida."); }
        var clinic = Guid.NewGuid();
        await using var session = await database.OpenAsync(identity, ct, tenant: clinic);
        if ((await session.QueryAsync("SELECT name FROM pg_timezone_names WHERE name = @zone", ct, ("zone", input.ZonaHoraria))).Count == 0)
            throw new DomainException(400, "La zona horaria debe ser un identificador IANA reconocido por PostgreSQL.");
        if ((await session.QueryAsync("SELECT id FROM med.resolve_identity(@id)", ct, ("id", input.AdministradorIdentidad))).Count > 0)
            throw new DomainException(409, "La identidad ya esta asociada a una clinica o a la plataforma.");
        await using var change = await directory.ChangeAsync(input.AdministradorIdentidad, input.NombreAdministrador, "clinic-admin", true,
            input.AdministradorNombreUsuario, input.AdministradorPassword, ct);
        var result = await session.OneAsync("INSERT INTO med.clinicas(id, identificador, nombre, zona_horaria) VALUES (@id, @code, @name, @zone) RETURNING *",
            ct, ("id", clinic), ("code", input.Identificador.Trim()), ("name", input.Nombre.Trim()), ("zone", input.ZonaHoraria));
        await session.ExecuteAsync("INSERT INTO med.usuarios(id, clinica_id, nombre, rol) VALUES (@id, @clinic, @name, 'clinic-admin')",
            ct, ("id", change.Id), ("clinic", clinic), ("name", input.NombreAdministrador.Trim()));
        await session.CommitAsync(ct);
        change.Accept();
        return StatusCode(201, result);
    }

    [HttpGet("usuarios")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Users(CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        return Ok(await s.QueryAsync("SELECT * FROM med.usuarios ORDER BY nombre", ct));
    }

    [HttpPost("usuarios")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> CreateUser(UsuarioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        if ((await s.QueryAsync("SELECT id FROM med.resolve_identity(@id)", ct, ("id", input.Identidad))).Count > 0)
            throw new DomainException(409, "La identidad ya esta asociada a una clinica o a la plataforma.");
        await using var change = await directory.ChangeAsync(input.Identidad, input.Nombre, input.Rol, input.Activo, input.NombreUsuario, input.Password, ct);
        var result = await s.OneAsync("INSERT INTO med.usuarios(id, clinica_id, nombre, rol, activo) VALUES (@id, @tenant, @name, @role, @active) RETURNING *",
            ct, ("id", change.Id), ("tenant", s.Identity.ClinicaId), ("name", input.Nombre.Trim()), ("role", input.Rol), ("active", input.Activo));
        await s.CommitAsync(ct);
        change.Accept();
        return StatusCode(201, result);
    }

    [HttpPut("usuarios/{id:guid}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> UpdateUser(Guid id, UsuarioInput input, CancellationToken ct)
    {
        if (input.Identidad != id) throw new DomainException(400, "La identidad no se puede modificar.");
        await using var s = await Open(ct, AdminRoles);
        await s.OneAsync("SELECT id FROM med.usuarios WHERE id = @id", ct, ("id", id));
        if (input.Rol != "professional" && (await s.QueryAsync("SELECT id FROM med.profesionales WHERE usuario_id = @id AND activo", ct, ("id", id))).Count > 0)
            throw new DomainException(409, "El usuario tiene un profesional activo asociado.");
        await using var change = await directory.ChangeAsync(id, input.Nombre, input.Rol, input.Activo, null, null, ct);
        var result = await s.OneAsync("UPDATE med.usuarios SET nombre = @name, rol = @role, activo = @active WHERE id = @id RETURNING *",
            ct, ("id", id), ("name", input.Nombre.Trim()), ("role", input.Rol), ("active", input.Activo));
        await s.CommitAsync(ct);
        change.Accept();
        return Ok(result);
    }

    [HttpDelete("usuarios/{id:guid}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> DisableUser(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var existing = await s.OneAsync("SELECT * FROM med.usuarios WHERE id = @id", ct, ("id", id));
        await using var change = await directory.ChangeAsync(id, (string)existing["nombre"]!, (string)existing["rol"]!, false, null, null, ct);
        await s.OneAsync("UPDATE med.usuarios SET activo = false WHERE id = @id RETURNING id", ct, ("id", id));
        await s.CommitAsync(ct);
        change.Accept();
        return NoContent();
    }

    [HttpGet("servicios")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Services(CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        return Ok(await s.QueryAsync("SELECT s.*, e.nombre AS especialidad FROM med.servicios s JOIN med.especialidades e ON e.id = s.especialidad_id ORDER BY s.nombre", ct));
    }

    [HttpPost("servicios")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> CreateService(ServicioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var specialty = await Specialty(s, input.Especialidad, ct);
        var result = await s.OneAsync("INSERT INTO med.servicios(clinica_id, nombre, duracion_minutos, especialidad_id, activo) VALUES (@tenant, @name, @duration, @specialty, @active) RETURNING *",
            ct, ("tenant", s.Identity.ClinicaId), ("name", input.Nombre.Trim()), ("duration", input.DuracionMinutos), ("specialty", specialty), ("active", input.Activo));
        await s.CommitAsync(ct);
        return StatusCode(201, result);
    }

    [HttpPut("servicios/{id:guid}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> UpdateService(Guid id, ServicioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var old = await s.OneAsync("SELECT * FROM med.servicios WHERE id = @id", ct, ("id", id));
        if ((int)old["duracionMinutos"]! != input.DuracionMinutos &&
            (await s.QueryAsync("SELECT id FROM med.citas WHERE servicio_id = @id LIMIT 1", ct, ("id", id))).Count > 0)
            throw new DomainException(409, "Cree otro servicio para cambiar la duracion de un servicio utilizado.");
        var specialty = await Specialty(s, input.Especialidad, ct);
        if ((Guid)old["especialidadId"]! != specialty &&
            (await s.QueryAsync("SELECT profesional_id FROM med.profesional_servicios WHERE servicio_id = @id LIMIT 1", ct, ("id", id))).Count > 0)
            throw new DomainException(409, "El servicio ya esta asociado a profesionales de otra especialidad.");
        var result = await s.OneAsync("UPDATE med.servicios SET nombre = @name, duracion_minutos = @duration, especialidad_id = @specialty, activo = @active WHERE id = @id RETURNING *",
            ct, ("id", id), ("name", input.Nombre.Trim()), ("duration", input.DuracionMinutos), ("specialty", specialty), ("active", input.Activo));
        await s.CommitAsync(ct);
        return Ok(result);
    }

    [HttpGet("profesionales")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Professionals(CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        return Ok(await s.QueryAsync("SELECT p.*, e.nombre AS especialidad FROM med.profesionales p JOIN med.especialidades e ON e.id = p.especialidad_id ORDER BY p.nombre", ct));
    }

    [HttpPost("profesionales")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> CreateProfessional(ProfesionalInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var user = await s.OneAsync("SELECT * FROM med.usuarios WHERE id = @id AND activo", ct, ("id", input.UsuarioId));
        if ((string)user["rol"]! != "professional") throw new DomainException(400, "El usuario debe tener rol profesional.");
        var specialty = await Specialty(s, input.Especialidad, ct);
        var result = await s.OneAsync("INSERT INTO med.profesionales(clinica_id, usuario_id, especialidad_id, nombre) VALUES (@tenant, @user, @specialty, @name) RETURNING *",
            ct, ("tenant", s.Identity.ClinicaId), ("user", input.UsuarioId), ("specialty", specialty), ("name", input.Nombre.Trim()));
        foreach (var service in input.Servicios.Distinct())
        {
            await s.OneAsync("SELECT id FROM med.servicios WHERE id = @id AND especialidad_id = @specialty AND activo", ct, ("id", service), ("specialty", specialty));
            await s.ExecuteAsync("INSERT INTO med.profesional_servicios VALUES (@tenant, @professional, @service)", ct,
                ("tenant", s.Identity.ClinicaId), ("professional", result["id"]), ("service", service));
        }
        await s.CommitAsync(ct);
        return StatusCode(201, result);
    }

    [HttpPost("profesionales/{id:guid}/servicios/{service:guid}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Associate(Guid id, Guid service, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        await s.OneAsync("SELECT p.id FROM med.profesionales p JOIN med.servicios s ON s.especialidad_id = p.especialidad_id WHERE p.id = @id AND s.id = @service", ct, ("id", id), ("service", service));
        await s.ExecuteAsync("INSERT INTO med.profesional_servicios VALUES (@tenant, @id, @service) ON CONFLICT DO NOTHING", ct,
            ("tenant", s.Identity.ClinicaId), ("id", id), ("service", service));
        await s.CommitAsync(ct);
        return NoContent();
    }

    [HttpGet("profesionales/{id:guid}/horarios")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> Hours(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        return Ok(await s.QueryAsync("SELECT * FROM med.horarios WHERE profesional_id = @id ORDER BY dia_semana, inicio", ct, ("id", id)));
    }

    [HttpPost("profesionales/{id:guid}/horarios")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> CreateHours(Guid id, HorarioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        if (input.Inicio >= input.Fin) throw new DomainException(400, "Rango horario invalido.");
        var result = await s.OneAsync("INSERT INTO med.horarios(clinica_id, profesional_id, dia_semana, inicio, fin) VALUES (@tenant, @id, @day, @start, @end) RETURNING *",
            ct, ("tenant", s.Identity.ClinicaId), ("id", id), ("day", input.DiaSemana), ("start", input.Inicio), ("end", input.Fin));
        await s.CommitAsync(ct);
        return StatusCode(201, result);
    }

    [HttpDelete("horarios/{id:guid}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> DeleteHours(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        var row = await s.OneAsync("SELECT * FROM med.horarios WHERE id = @id", ct, ("id", id));
        OwnProfessional(s, (Guid)row["profesionalId"]!);
        if ((await s.QueryAsync("SELECT id FROM med.citas WHERE profesional_id = @id AND estado = 'reservada' LIMIT 1", ct, ("id", row["profesionalId"]))).Count > 0)
            throw new DomainException(409, "Reprograme las citas vigentes antes de retirar horarios.");
        await s.ExecuteAsync("DELETE FROM med.horarios WHERE id = @id", ct, ("id", id));
        await s.CommitAsync(ct);
        return NoContent();
    }

    [HttpGet("profesionales/{id:guid}/bloqueos")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> Blocks(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        return Ok(await s.QueryAsync("SELECT * FROM med.bloqueos WHERE profesional_id = @id ORDER BY inicio", ct, ("id", id)));
    }

    [HttpPost("profesionales/{id:guid}/bloqueos")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> CreateBlock(Guid id, BloqueoInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        if (input.Inicio >= input.Fin) throw new DomainException(400, "Rango de bloqueo invalido.");
        var result = await s.OneAsync("INSERT INTO med.bloqueos(clinica_id, profesional_id, inicio, fin, motivo) VALUES (@tenant, @id, @start, @end, @reason) RETURNING *",
            ct, ("tenant", s.Identity.ClinicaId), ("id", id), ("start", input.Inicio.UtcDateTime), ("end", input.Fin.UtcDateTime), ("reason", input.Motivo.Trim()));
        var conflicts = await s.QueryAsync("SELECT * FROM med.citas WHERE profesional_id = @id AND estado = 'reservada' AND inicio < @end AND fin > @start", ct,
            ("id", id), ("start", input.Inicio.UtcDateTime), ("end", input.Fin.UtcDateTime));
        await s.CommitAsync(ct);
        return StatusCode(201, new { bloqueo = result, conflictos = conflicts });
    }

    [HttpDelete("bloqueos/{id:guid}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> DeleteBlock(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        var row = await s.OneAsync("SELECT * FROM med.bloqueos WHERE id = @id", ct, ("id", id));
        OwnProfessional(s, (Guid)row["profesionalId"]!);
        await s.ExecuteAsync("DELETE FROM med.bloqueos WHERE id = @id", ct, ("id", id));
        await s.CommitAsync(ct);
        return NoContent();
    }

    [HttpGet("disponibilidad")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Available(Guid profesionalId, Guid servicioId, DateOnly fecha, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        if (fecha == default || fecha == DateOnly.MaxValue) throw new DomainException(400, "Fecha invalida.");
        return Ok(await availability.GetAsync(s, profesionalId, servicioId, fecha, ct));
    }

    [HttpGet("disponibilidad/servicios/{id:guid}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> AvailableService(Guid id, DateOnly desde, DateOnly hasta, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        ValidateRange(desde, hasta, 31);
        var professionals = await s.QueryAsync("SELECT p.id FROM med.profesionales p JOIN med.profesional_servicios ps ON ps.profesional_id = p.id JOIN med.servicios sv ON sv.id = ps.servicio_id WHERE ps.servicio_id = @id AND p.activo AND sv.activo", ct, ("id", id));
        var result = new List<AvailabilityResult>();
        foreach (var professional in professionals)
            for (var day = desde; day <= hasta; day = day.AddDays(1))
            {
                var available = await availability.GetAsync(s, (Guid)professional["id"]!, id, day, ct);
                if (available.Espacios.Count > 0) result.Add(available);
            }
        return Ok(result);
    }

    [HttpGet("pacientes")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Patients(CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var rows = await s.QueryAsync("SELECT * FROM med.pacientes ORDER BY nombre", ct);
        foreach (var row in rows) await s.AuditAsync((Guid)row["id"]!, "contacto.lectura", (Guid)row["id"]!, ct);
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpGet("pacientes/{id:guid}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Patient(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var row = await s.OneAsync("SELECT * FROM med.pacientes WHERE id = @id", ct, ("id", id));
        await s.AuditAsync(id, "contacto.lectura", id, ct);
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpPost("pacientes")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> CreatePatient(PacienteInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        if (input.FechaNacimiento == default || input.FechaNacimiento > DateOnly.FromDateTime(DateTime.UtcNow)) throw new DomainException(400, "Fecha de nacimiento invalida.");
        var row = await s.OneAsync("INSERT INTO med.pacientes(clinica_id, identificacion, nombre, fecha_nacimiento, contacto) VALUES (@tenant, @code, @name, @birth, @contact) RETURNING *",
            ct, ("tenant", s.Identity.ClinicaId), ("code", input.Identificacion.Trim()), ("name", input.Nombre.Trim()), ("birth", input.FechaNacimiento), ("contact", input.Contacto.Trim()));
        await s.AuditAsync((Guid)row["id"]!, "contacto.escritura", (Guid)row["id"]!, ct);
        await s.CommitAsync(ct);
        return StatusCode(201, row);
    }

    [HttpPut("pacientes/{id:guid}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> UpdatePatient(Guid id, PacienteInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        if (input.FechaNacimiento == default || input.FechaNacimiento > DateOnly.FromDateTime(DateTime.UtcNow)) throw new DomainException(400, "Fecha de nacimiento invalida.");
        var row = await s.OneAsync("UPDATE med.pacientes SET identificacion = @code, nombre = @name, fecha_nacimiento = @birth, contacto = @contact WHERE id = @id RETURNING *",
            ct, ("id", id), ("code", input.Identificacion.Trim()), ("name", input.Nombre.Trim()), ("birth", input.FechaNacimiento), ("contact", input.Contacto.Trim()));
        await s.AuditAsync(id, "contacto.escritura", id, ct);
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpGet("pacientes/{id:guid}/historial")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> History(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        await s.OneAsync("SELECT id FROM med.pacientes WHERE id = @id", ct, ("id", id));
        return Ok(await s.QueryAsync("SELECT * FROM med.citas WHERE paciente_id = @id ORDER BY inicio DESC", ct, ("id", id)));
    }

    [HttpPost("citas")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Book(CitaInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        var row = await InsertAppointment(s, input, null, ct);
        await s.CommitAsync(ct);
        return StatusCode(201, row);
    }

    private static Task<Dictionary<string, object?>> InsertAppointment(MedicalSession s, CitaInput input, Guid? previous, CancellationToken ct)
    {
        if (input.Inicio.Year is < 2000 or > 2100 || input.PacienteId == Guid.Empty || input.ProfesionalId == Guid.Empty || input.ServicioId == Guid.Empty)
            throw new DomainException(400, "Datos de cita invalidos.");
        return s.OneAsync("""
            INSERT INTO med.citas(clinica_id, paciente_id, profesional_id, servicio_id, inicio, fin, usuario_modificacion, anterior_id)
            VALUES (@tenant, @patient, @professional, @service, @start, @start, @user, @previous) RETURNING *
            """, ct, ("tenant", s.Identity.ClinicaId), ("patient", input.PacienteId), ("professional", input.ProfesionalId),
            ("service", input.ServicioId), ("start", input.Inicio.UtcDateTime), ("user", s.Identity.Id), ("previous", previous));
    }

    [HttpGet("citas/{id:guid}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Appointment(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var row = await s.OneAsync("SELECT * FROM med.citas WHERE id = @id", ct, ("id", id));
        OwnProfessional(s, (Guid)row["profesionalId"]!);
        return Ok(row);
    }

    [HttpPost("citas/{id:guid}/reprogramar")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Reschedule(Guid id, ReprogramarInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        var old = await s.OneAsync("SELECT * FROM med.citas WHERE id = @id", ct, ("id", id));
        if ((string)old["estado"]! != "reservada") throw new DomainException(409, "La cita ya esta en un estado final.");
        await s.ExecuteAsync("UPDATE med.citas SET estado = 'reprogramada', usuario_modificacion = @user WHERE id = @id", ct, ("id", id), ("user", s.Identity.Id));
        var row = await InsertAppointment(s, new CitaInput((Guid)old["pacienteId"]!, input.ProfesionalId, input.ServicioId, input.Inicio), id, ct);
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpPost("citas/{id:guid}/cancelar")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Cancel(Guid id, MotivoInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        var row = await s.OneAsync("UPDATE med.citas SET estado = 'cancelada', motivo = @reason, usuario_modificacion = @user WHERE id = @id RETURNING *", ct,
            ("id", id), ("reason", input.Motivo.Trim()), ("user", s.Identity.Id));
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpPost("citas/{id:guid}/desenlace")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Outcome(Guid id, DesenlaceInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var old = await s.OneAsync("SELECT * FROM med.citas WHERE id = @id", ct, ("id", id));
        OwnProfessional(s, (Guid)old["profesionalId"]!);
        var row = await s.OneAsync("UPDATE med.citas SET estado = @state, usuario_modificacion = @user WHERE id = @id RETURNING *", ct,
            ("id", id), ("state", input.Estado), ("user", s.Identity.Id));
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpPost("citas/{id:guid}/nota")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "professional")]
    public async Task<IActionResult> AddNote(Guid id, NotaInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ["professional"]);
        var appointment = await s.OneAsync("SELECT * FROM med.citas WHERE id = @id", ct, ("id", id));
        OwnProfessional(s, (Guid)appointment["profesionalId"]!);
        if ((string)appointment["estado"]! != "atendida") throw new DomainException(409, "La cita debe estar atendida.");
        var row = await s.OneAsync("INSERT INTO med.notas(clinica_id, cita_id, profesional_id, contenido) VALUES (@tenant, @id, @professional, @content) RETURNING *", ct,
            ("tenant", s.Identity.ClinicaId), ("id", id), ("professional", s.Identity.ProfesionalId), ("content", input.Contenido.Trim()));
        await s.AuditAsync((Guid)appointment["pacienteId"]!, "nota.escritura", (Guid)row["id"]!, ct);
        await s.CommitAsync(ct);
        return StatusCode(201, row);
    }

    [HttpGet("citas/{id:guid}/nota")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "professional")]
    public async Task<IActionResult> Note(Guid id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["professional"]);
        var appointment = await s.OneAsync("SELECT * FROM med.citas WHERE id = @id", ct, ("id", id));
        OwnProfessional(s, (Guid)appointment["profesionalId"]!);
        var row = await s.OneAsync("SELECT * FROM med.notas WHERE cita_id = @id", ct, ("id", id));
        await s.AuditAsync((Guid)appointment["pacienteId"]!, "nota.lectura", (Guid)row["id"]!, ct);
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpGet("agenda")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Agenda(DateOnly fecha, Guid? profesionalId, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        if (fecha == default) throw new DomainException(400, "Fecha obligatoria.");
        if (s.Identity.Rol == "professional")
        {
            if (s.Identity.ProfesionalId is null) throw new DomainException(403, "Profesional no asociado.");
            if (profesionalId.HasValue) OwnProfessional(s, profesionalId.Value);
            profesionalId = s.Identity.ProfesionalId;
        }
        return Ok(await s.QueryAsync("""
            SELECT a.*, EXISTS(SELECT FROM med.bloqueos b WHERE b.profesional_id = a.profesional_id
                AND b.inicio < a.fin AND b.fin > a.inicio AND a.estado = 'reservada') AS conflicto
            FROM med.citas a JOIN med.clinicas c ON c.id = a.clinica_id
            WHERE (a.inicio AT TIME ZONE c.zona_horaria)::date = @date
                AND (@professional::uuid IS NULL OR a.profesional_id = @professional) ORDER BY a.inicio
            """, ct, ("date", fecha), ("professional", profesionalId)));
    }

    [HttpGet("estadisticas/citas")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Statistics(DateOnly desde, DateOnly hasta, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        ValidateRange(desde, hasta, 3660);
        return Ok(await s.QueryAsync("""
            SELECT a.estado, count(*) AS cantidad FROM med.citas a JOIN med.clinicas c ON c.id = a.clinica_id
            WHERE (a.inicio AT TIME ZONE c.zona_horaria)::date BETWEEN @start AND @end GROUP BY a.estado ORDER BY a.estado
            """, ct, ("start", desde), ("end", hasta)));
    }

    [HttpGet("auditoria")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Audit(Guid? usuarioId, Guid? pacienteId, DateTimeOffset? desde, DateTimeOffset? hasta, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles, true);
        if (desde.HasValue && hasta.HasValue && desde > hasta) throw new DomainException(400, "Rango invalido.");
        return Ok(await s.QueryAsync("""
            SELECT id, clinica_id, paciente_id, usuario_id, accion, recurso_id, instante, anterior, huella FROM med.auditoria
            WHERE (@user::uuid IS NULL OR usuario_id = @user) AND (@patient::uuid IS NULL OR paciente_id = @patient)
                AND (@start::timestamptz IS NULL OR instante >= @start) AND (@end::timestamptz IS NULL OR instante <= @end)
            ORDER BY id
            """, ct, ("user", usuarioId), ("patient", pacienteId), ("start", desde?.UtcDateTime), ("end", hasta?.UtcDateTime)));
    }

    [HttpGet("auditoria/verificar")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> VerifyAudit(CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles, true);
        var result = await s.OneAsync("""
            WITH cadena AS (
                SELECT *, coalesce(lag(huella) OVER (ORDER BY id), '') AS previa FROM med.auditoria
            ), ultimo AS (SELECT id, huella FROM med.auditoria ORDER BY id DESC LIMIT 1)
            SELECT (SELECT count(*) FROM cadena) AS registros,
                coalesce((SELECT bool_and(anterior = previa AND huella = encode(public.digest(anterior || payload::text, 'sha256'), 'hex')
                    AND (payload->>'clinica')::uuid = clinica_id AND (payload->>'usuario')::uuid = usuario_id
                    AND (payload->>'paciente')::uuid = paciente_id AND payload->>'accion' = accion
                    AND (payload->>'recurso')::uuid = recurso_id AND (payload->>'instante')::timestamptz = instante) FROM cadena), true)
                AND coalesce((SELECT u.id = h.ultimo_id AND u.huella = h.huella FROM ultimo u CROSS JOIN med.audit_heads h),
                    NOT EXISTS(SELECT FROM med.audit_heads)) AS valida
            """, ct);
        return Ok(result);
    }

    private static void ValidateRange(DateOnly start, DateOnly end, int maxDays)
    {
        if (start == default || end == default || end == DateOnly.MaxValue || end < start || end.DayNumber - start.DayNumber > maxDays)
            throw new DomainException(400, $"Rango invalido; maximo {maxDays} dias.");
    }
}
