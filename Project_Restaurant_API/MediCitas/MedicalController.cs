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
    private static readonly string[] ClinicRoles = ["clinic-admin", "reception", "professional"];
    private static readonly string[] ReceptionRoles = ["clinic-admin", "reception"];
    private static readonly string[] AdminRoles = ["clinic-admin"];

    private async Task<MedicalSession> Open(CancellationToken ct, string[] roles)
    {
        var identity = await database.ResolveAsync(User, ct);
        if (!roles.Contains(identity.Rol))
            throw new DomainException(403, "Operacion no permitida para este rol.");
        foreach (var key in new[] { "clinicaId", "clinica_id", "idClinica", "id_clinica", "tenantId", "tenant_id" })
            if (Request.Query.TryGetValue(key, out var value) && value != identity.ClinicaId?.ToString())
                throw new DomainException(403, "La clinica se obtiene exclusivamente de la identidad.");
        return await database.OpenAsync(identity, ct, clientIp: HttpContext.Connection.RemoteIpAddress);
    }

    private static void OwnProfessional(MedicalSession session, int professionalId)
    {
        if (session.Identity.Rol == "professional" && session.Identity.ProfesionalId != professionalId)
            throw new DomainException(403, "Solo puede operar sobre su propia agenda.");
    }

    private static async Task<int> ResolveSpecialtyAsync(MedicalSession session, int? idEspecialidad, string? especialidad, CancellationToken ct)
    {
        if (idEspecialidad is > 0) return idEspecialidad.Value;
        if (string.IsNullOrWhiteSpace(especialidad))
            throw new DomainException(400, "Debe indicar la especialidad.");
        var outRow = await session.CallOutAsync(
            "SP_ResolverEspecialidad",
            2,
            ct,
            ("userName", session.Identity.NombreUsuario),
            ("nombre", especialidad.Trim()));
        return Convert.ToInt32(outRow["outidespecialidad"]!);
    }

    private static (string? Telefono, string? Correo) ExtractContact(PacienteInput input)
    {
        var telefono = string.IsNullOrWhiteSpace(input.Telefono) ? null : input.Telefono.Trim();
        var correo = string.IsNullOrWhiteSpace(input.Correo) ? null : input.Correo.Trim();
        if (telefono is null && correo is null && !string.IsNullOrWhiteSpace(input.Contacto))
        {
            var contact = input.Contacto.Trim();
            if (contact.Contains('@')) correo = contact[..Math.Min(contact.Length, 32)];
            else telefono = contact[..Math.Min(contact.Length, 20)];
        }
        return (telefono, correo);
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

        await using var session = await database.OpenAsync(identity, ct, clientIp: HttpContext.Connection.RemoteIpAddress);
        await using var change = await directory.ChangeAsync(
            input.AdministradorIdentidad,
            input.NombreAdministrador,
            "clinic-admin",
            true,
            input.AdministradorNombreUsuario,
            input.AdministradorPassword,
            ct);

        var correoAdmin = string.IsNullOrWhiteSpace(input.CorreoAdministrador)
            ? $"{(input.AdministradorNombreUsuario ?? "admin").Trim()}@mc.test"
            : input.CorreoAdministrador.Trim();
        if (correoAdmin.Length > 32) correoAdmin = correoAdmin[..32];

        var outRow = await session.CallOutAsync(
            "SP_AltaClinica",
            3,
            ct,
            ("userName", identity.NombreUsuario),
            ("nombre", input.Nombre.Trim()),
            ("zonaHoraria", input.ZonaHoraria.Trim()),
            ("identificador", input.Identificador.Trim()),
            ("nombreAdmin", input.NombreAdministrador.Trim()),
            ("correoAdmin", correoAdmin),
            ("tokenSubAdmin", change.Id.ToString()));

        await session.CommitAsync(ct);
        change.Accept();

        var idClinica = Convert.ToInt32(outRow["outidclinica"]!);
        var idUsuarioAdmin = Convert.ToInt32(outRow["outidusuarioadmin"]!);
        return StatusCode(201, new
        {
            id = idClinica,
            nombre = input.Nombre.Trim(),
            identificador = input.Identificador.Trim(),
            zonaHoraria = input.ZonaHoraria.Trim(),
            idUsuarioAdmin,
            tokenSubAdmin = change.Id
        });
    }

    [HttpGet("usuarios")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Users(CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var rows = await s.CallCursorAsync("SP_ListarUsuarios", ct, ("userName", s.Identity.NombreUsuario));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpPost("usuarios")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> CreateUser(UsuarioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var idRol = MedicalDatabase.MapRoleId(input.Rol);
        await using var change = await directory.ChangeAsync(
            input.Identidad,
            input.Nombre,
            input.Rol,
            input.Activo,
            input.NombreUsuario,
            input.Password,
            ct);

        var correo = string.IsNullOrWhiteSpace(input.Correo)
            ? $"{(input.NombreUsuario ?? Guid.NewGuid().ToString("N")[..8]).Trim()}@mc{s.Identity.ClinicaId}.test"
            : input.Correo.Trim();
        if (correo.Length > 32) correo = correo[..32];

        var outRow = await s.CallOutAsync(
            "SP_CrearUsuario",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("nombreUsuario", input.Nombre.Trim()),
            ("correo", correo),
            ("tokenSub", change.Id.ToString()),
            ("idRol", idRol));

        var idUsuario = Convert.ToInt32(outRow["outidusuario"]!);
        if (!input.Activo)
        {
            await s.CallOutAsync("SP_DarBajaUsuario", 1, ct,
                ("userName", s.Identity.NombreUsuario),
                ("idUsuario", idUsuario));
        }

        await s.CommitAsync(ct);
        change.Accept();
        return StatusCode(201, new
        {
            id = idUsuario,
            idClinica = s.Identity.ClinicaId,
            idRol,
            rol = input.Rol,
            nombre = input.Nombre.Trim(),
            correo,
            tokenSub = change.Id.ToString(),
            activo = input.Activo
        });
    }

    [HttpPut("usuarios/{id:int}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> UpdateUser(int id, UsuarioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var users = await s.CallCursorAsync("SP_ListarUsuarios", ct, ("userName", s.Identity.NombreUsuario));
        var existing = users.FirstOrDefault(u => Convert.ToInt32(u["id"]) == id)
            ?? throw new DomainException(404, "Usuario no encontrado.");

        var idRol = MedicalDatabase.MapRoleId(input.Rol);
        await s.CallOutAsync(
            "SP_CambiarRolUsuario",
            1,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", id),
            ("idRol", idRol));

        if (!input.Activo)
        {
            await s.CallOutAsync("SP_DarBajaUsuario", 1, ct,
                ("userName", s.Identity.NombreUsuario),
                ("idUsuario", id));
        }

        IdentityChange? change = null;
        if (Guid.TryParse(existing["tokenSub"]?.ToString(), out var kcId))
        {
            change = await directory.ChangeAsync(kcId, input.Nombre, input.Rol, input.Activo, null, null, ct);
        }

        await s.CommitAsync(ct);
        change?.Accept();
        if (change is not null) await change.DisposeAsync();

        return Ok(new
        {
            id,
            idClinica = s.Identity.ClinicaId,
            idRol,
            rol = input.Rol,
            nombre = input.Nombre.Trim(),
            activo = input.Activo
        });
    }

    [HttpDelete("usuarios/{id:int}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> DisableUser(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var users = await s.CallCursorAsync("SP_ListarUsuarios", ct, ("userName", s.Identity.NombreUsuario));
        var existing = users.FirstOrDefault(u => Convert.ToInt32(u["id"]) == id)
            ?? throw new DomainException(404, "Usuario no encontrado.");

        await s.CallOutAsync(
            "SP_DarBajaUsuario",
            1,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", id));

        IdentityChange? change = null;
        if (Guid.TryParse(existing["tokenSub"]?.ToString(), out var kcId))
        {
            var role = MedicalDatabase.MapRoleName(Convert.ToInt32(existing["idRol"]!));
            change = await directory.ChangeAsync(kcId, existing["nombreUsuario"]?.ToString() ?? "usuario", role, false, null, null, ct);
        }

        await s.CommitAsync(ct);
        change?.Accept();
        if (change is not null) await change.DisposeAsync();
        return NoContent();
    }

    [HttpGet("servicios")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Services(CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var rows = await s.CallCursorAsync("SP_ListarServicios", ct, ("userName", s.Identity.NombreUsuario));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpPost("servicios")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> CreateService(ServicioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var idEspecialidad = await ResolveSpecialtyAsync(s, input.IdEspecialidad, input.Especialidad, ct);
        var outRow = await s.CallOutAsync(
            "SP_CrearServicio",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("nombre", input.Nombre.Trim()),
            ("duracionMin", input.DuracionMinutos),
            ("idEspecialidad", idEspecialidad));
        await s.CommitAsync(ct);
        var idServicio = Convert.ToInt32(outRow["outidservicio"]!);
        return StatusCode(201, new
        {
            id = idServicio,
            idClinica = s.Identity.ClinicaId,
            idEspecialidad,
            nombre = input.Nombre.Trim(),
            duracionMin = input.DuracionMinutos
        });
    }

    [HttpPut("servicios/{id:int}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> UpdateService(int id, ServicioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var idEspecialidad = await ResolveSpecialtyAsync(s, input.IdEspecialidad, input.Especialidad, ct);
        await s.CallOutAsync(
            "SP_ActualizarServicio",
            1,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idServicio", id),
            ("nombre", input.Nombre.Trim()),
            ("duracionMin", input.DuracionMinutos),
            ("idEspecialidad", idEspecialidad));
        var pros = await s.CallCursorAsync("SP_ListarProfesionales", ct, ("userName", s.Identity.NombreUsuario));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalsAsync(
            s.Identity.ClinicaId!.Value,
            pros.Select(p => Convert.ToInt32(p["id"]!)));
        return Ok(new
        {
            id,
            idClinica = s.Identity.ClinicaId,
            idEspecialidad,
            nombre = input.Nombre.Trim(),
            duracionMin = input.DuracionMinutos
        });
    }

    [HttpGet("profesionales")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Professionals(CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var rows = await s.CallCursorAsync("SP_ListarProfesionales", ct, ("userName", s.Identity.NombreUsuario));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpPost("profesionales")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> CreateProfessional(ProfesionalInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        var idEspecialidad = await ResolveSpecialtyAsync(s, input.IdEspecialidad, input.Especialidad, ct);
        var outRow = await s.CallOutAsync(
            "SP_CrearProfesional",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", input.UsuarioId),
            ("idEspecialidad", idEspecialidad));
        var idProfesional = Convert.ToInt32(outRow["outidprofesional"]!);

        foreach (var serviceId in (input.Servicios ?? []).Distinct())
        {
            await s.CallOutAsync(
                "SP_AsignarServicioProfesional",
                2,
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idProfesional", idProfesional),
                ("idServicio", serviceId));
        }

        await s.CommitAsync(ct);
        return StatusCode(201, new
        {
            id = idProfesional,
            idClinica = s.Identity.ClinicaId,
            idUsuario = input.UsuarioId,
            idEspecialidad
        });
    }

    [HttpPost("profesionales/{id:int}/servicios/{service:int}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Associate(int id, int service, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        await s.CallOutAsync(
            "SP_AsignarServicioProfesional",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idProfesional", id),
            ("idServicio", service));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, id);
        return NoContent();
    }

    [HttpDelete("profesionales/{id:int}/servicios/{service:int}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Disassociate(int id, int service, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        await s.CallOutAsync(
            "SP_QuitarServicioProfesional",
            1,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idProfesional", id),
            ("idServicio", service));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, id);
        return NoContent();
    }

    [HttpGet("profesionales/{id:int}/horarios")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> Hours(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        var rows = await s.CallCursorAsync(
            "SP_ListarHorariosProfesional",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idProfesional", id));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpPost("profesionales/{id:int}/horarios")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> CreateHours(int id, HorarioInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        if (input.Inicio >= input.Fin) throw new DomainException(400, "Rango horario invalido.");
        var outRow = await s.CallOutAsync(
            "SP_AgregarHorarioAtencion",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idProfesional", id),
            ("dia", input.DiaSemana),
            ("horaInicio", input.Inicio),
            ("horaFin", input.Fin));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, id);
        return StatusCode(201, new
        {
            id = Convert.ToInt32(outRow["outidhorario"]!),
            idClinica = s.Identity.ClinicaId,
            idProfesional = id,
            dia = input.DiaSemana,
            horaInicio = input.Inicio,
            horaFin = input.Fin
        });
    }

    [HttpDelete("horarios/{id:int}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> DeleteHours(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        int? targetProfessional = s.Identity.ProfesionalId;
        if (s.Identity.Rol == "professional")
        {
            if (targetProfessional is null) throw new DomainException(403, "Profesional no asociado.");
            var ownHours = await s.CallCursorAsync(
                "SP_ListarHorariosProfesional",
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idProfesional", targetProfessional.Value));
            if (ownHours.All(h => Convert.ToInt32(h["id"]) != id))
                throw new DomainException(403, "Solo puede operar sobre su propia agenda.");
        }

        await s.CallOutAsync(
            "SP_EliminarHorarioAtencion",
            1,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idHorario", id));
        var pros = await s.CallCursorAsync("SP_ListarProfesionales", ct, ("userName", s.Identity.NombreUsuario));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalsAsync(
            s.Identity.ClinicaId!.Value,
            pros.Select(p => Convert.ToInt32(p["id"]!)));
        return NoContent();
    }

    [HttpGet("profesionales/{id:int}/bloqueos")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> Blocks(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        var rows = await s.CallCursorAsync(
            "SP_ListarBloqueosProfesional",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idProfesional", id));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpPost("profesionales/{id:int}/bloqueos")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> CreateBlock(int id, BloqueoInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        OwnProfessional(s, id);
        if (input.Inicio >= input.Fin) throw new DomainException(400, "Rango de bloqueo invalido.");
        var motivoEnum = input.Motivo.Trim().StartsWith("vac", StringComparison.OrdinalIgnoreCase)
            ? "vacaciones"
            : "permisos";
        var outRow = await s.CallOutAsync(
            "SP_RegistrarBloqueoAgenda",
            3,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idProfesional", id),
            ("idServicio", input.ServicioId),
            ("idUsuario", s.Identity.Id),
            ("horaInicio", input.Inicio.UtcDateTime),
            ("horaFin", input.Fin.UtcDateTime),
            ("motivo", motivoEnum));
        var idBloqueo = Convert.ToInt32(outRow["outidbloqueo"]!);
        var cantidadConflictos = Convert.ToInt32(outRow["outcantidadconflictos"] ?? 0);
        var conflicts = await s.CallCursorAsync(
            "SP_ListarConflictosBloqueo",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idBloqueo", idBloqueo));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, id);
        return StatusCode(201, new
        {
            bloqueo = new
            {
                id = idBloqueo,
                idClinica = s.Identity.ClinicaId,
                idProfesional = id,
                idServicio = input.ServicioId,
                idUsuario = s.Identity.Id,
                horaInicio = input.Inicio.UtcDateTime,
                horaFin = input.Fin.UtcDateTime,
                motivo = motivoEnum
            },
            cantidadConflictos,
            conflictos = conflicts
        });
    }

    [HttpGet("bloqueos/{id:int}/conflictos")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> BlockConflicts(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var conflicts = await s.CallCursorAsync(
            "SP_ListarConflictosBloqueo",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idBloqueo", id));
        await s.CommitAsync(ct);
        return Ok(conflicts);
    }

    [HttpDelete("bloqueos/{id:int}")]
    [ProducesResponseType(204)]
    [Authorize(Roles = "clinic-admin,professional")]
    public async Task<IActionResult> DeleteBlock(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["clinic-admin", "professional"]);
        if (s.Identity.Rol == "professional")
        {
            if (s.Identity.ProfesionalId is null) throw new DomainException(403, "Profesional no asociado.");
            var ownBlocks = await s.CallCursorAsync(
                "SP_ListarBloqueosProfesional",
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idProfesional", s.Identity.ProfesionalId.Value));
            if (ownBlocks.All(b => Convert.ToInt32(b["id"]) != id))
                throw new DomainException(403, "Solo puede operar sobre su propia agenda.");
        }

        var outRow = await s.CallOutAsync(
            "SP_EliminarBloqueoAgenda",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idBloqueo", id));
        var idProfesional = Convert.ToInt32(outRow["outidprofesional"]!);
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, idProfesional);
        return NoContent();
    }

    [HttpGet("disponibilidad")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Available(int profesionalId, int servicioId, DateOnly fecha, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        if (profesionalId <= 0 || servicioId <= 0 || fecha == default || fecha == DateOnly.MaxValue)
            throw new DomainException(400, "Parametros de disponibilidad invalidos.");
        var result = await availability.GetAsync(s, profesionalId, servicioId, fecha, ct);
        await s.CommitAsync(ct);
        return Ok(result);
    }

    [HttpGet("disponibilidad/servicios/{id:int}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> AvailableService(int id, DateOnly desde, DateOnly hasta, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        ValidateRange(desde, hasta, 61);
        var rows = await s.CallCursorAsync(
            "SP_ConsultarDisponibilidadServicio",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idServicio", id),
            ("fechaDesde", desde),
            ("fechaHasta", hasta));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpGet("pacientes")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Patients([FromQuery] string? texto, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var rows = await s.CallCursorAsync(
            "SP_BuscarPacientes",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("texto", texto ?? ""));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpGet("pacientes/{id:int}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Patient(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarPaciente",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", s.Identity.Id),
            ("ip", s.ClientIp),
            ("idPaciente", id));
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpPost("pacientes")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> CreatePatient(PacienteInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        if (input.FechaNacimiento == default || input.FechaNacimiento > DateOnly.FromDateTime(DateTime.UtcNow))
            throw new DomainException(400, "Fecha de nacimiento invalida.");
        var (telefono, correo) = ExtractContact(input);
        var outRow = await s.CallOutAsync(
            "SP_CrearPaciente",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", s.Identity.Id),
            ("ip", s.ClientIp),
            ("identificacion", input.Identificacion.Trim()),
            ("nombre", input.Nombre.Trim()),
            ("fechaNacimiento", input.FechaNacimiento),
            ("telefono", telefono),
            ("correo", correo));
        var idPaciente = Convert.ToInt32(outRow["outidpaciente"]!);
        await s.CommitAsync(ct);
        return StatusCode(201, new
        {
            id = idPaciente,
            idClinica = s.Identity.ClinicaId,
            identificacion = input.Identificacion.Trim(),
            nombre = input.Nombre.Trim(),
            fechaNacimiento = input.FechaNacimiento,
            telefono,
            correo
        });
    }

    [HttpPut("pacientes/{id:int}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> UpdatePatient(int id, PacienteInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        if (input.FechaNacimiento == default || input.FechaNacimiento > DateOnly.FromDateTime(DateTime.UtcNow))
            throw new DomainException(400, "Fecha de nacimiento invalida.");
        var (telefono, correo) = ExtractContact(input);
        await s.CallOutAsync(
            "SP_ActualizarPaciente",
            1,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", s.Identity.Id),
            ("ip", s.ClientIp),
            ("idPaciente", id),
            ("identificacion", input.Identificacion.Trim()),
            ("nombre", input.Nombre.Trim()),
            ("fechaNacimiento", input.FechaNacimiento),
            ("telefono", telefono),
            ("correo", correo));
        await s.CommitAsync(ct);
        return Ok(new
        {
            id,
            idClinica = s.Identity.ClinicaId,
            identificacion = input.Identificacion.Trim(),
            nombre = input.Nombre.Trim(),
            fechaNacimiento = input.FechaNacimiento,
            telefono,
            correo
        });
    }

    [HttpGet("pacientes/{id:int}/historial")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> History(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var rows = await s.CallCursorAsync(
            "SP_ConsultarHistorialPaciente",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idPaciente", id));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpPost("citas")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Book(CitaInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        if (input.Inicio.Year is < 2000 or > 2100 || input.PacienteId <= 0 || input.ProfesionalId <= 0 || input.ServicioId <= 0)
            throw new DomainException(400, "Datos de cita invalidos.");
        var outRow = await s.CallOutAsync(
            "SP_ReservarCita",
            2,
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idPaciente", input.PacienteId),
            ("idProfesional", input.ProfesionalId),
            ("idServicio", input.ServicioId),
            ("horaInicio", input.Inicio.UtcDateTime));
        var idCita = Convert.ToInt32(outRow["outidcita"]!);
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", idCita));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, input.ProfesionalId);
        return StatusCode(201, row);
    }

    [HttpGet("citas/{id:int}")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Appointment(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        OwnProfessional(s, Convert.ToInt32(row["idProfesional"]!));
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpPost("citas/{id:int}/reprogramar")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Reschedule(int id, ReprogramarInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        var old = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        var oldProf = Convert.ToInt32(old["idProfesional"]!);
        var oldEstado = old["estado"]?.ToString();
        Dictionary<string, object?> outRow;
        try
        {
            outRow = await s.CallOutAsync(
                "SP_ReprogramarCita",
                2,
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idCita", id),
                ("nuevaHoraInicio", input.Inicio.UtcDateTime),
                ("nuevoIdProfesional", input.ProfesionalId));
        }
        catch (DomainException ex) when (ex.Status == 400 && oldEstado != "reservada")
        {
            throw new DomainException(409, "La cita ya se encuentra en un estado final y no admite cambios.");
        }
        var idCitaNueva = Convert.ToInt32(outRow["outidcitanueva"]!);
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", idCitaNueva));
        await s.CommitAsync(ct);
        var newProf = Convert.ToInt32(row["idProfesional"]!);
        await availability.InvalidateProfessionalsAsync(s.Identity.ClinicaId!.Value, [oldProf, newProf]);
        return Ok(row);
    }

    [HttpPost("citas/{id:int}/cancelar")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Cancel(int id, MotivoInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        var old = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        var idProfesional = Convert.ToInt32(old["idProfesional"]!);
        var oldEstado = old["estado"]?.ToString();
        try
        {
            await s.CallOutAsync(
                "SP_CancelarCita",
                1,
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idCita", id),
                ("motivo", input.Motivo.Trim()),
                ("idUsuario", s.Identity.Id));
        }
        catch (DomainException ex) when (ex.Status == 400 && oldEstado != "reservada")
        {
            throw new DomainException(409, "La cita ya se encuentra en un estado final y no admite cambios.");
        }
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, idProfesional);
        return Ok(row);
    }

    [HttpPost("citas/{id:int}/desenlace")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Outcome(int id, DesenlaceInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        var old = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        var idProfesional = Convert.ToInt32(old["idProfesional"]!);
        var oldEstado = old["estado"]?.ToString();
        OwnProfessional(s, idProfesional);
        try
        {
            await s.CallOutAsync(
                "SP_RegistrarDesenlaceCita",
                1,
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idCita", id),
                ("estado", input.Estado));
        }
        catch (DomainException ex) when (ex.Status == 400 && oldEstado != "reservada")
        {
            throw new DomainException(409, "La cita ya se encuentra en un estado final y no admite cambios.");
        }
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        await s.CommitAsync(ct);
        await availability.InvalidateProfessionalAsync(s.Identity.ClinicaId!.Value, idProfesional);
        return Ok(row);
    }

    [HttpPost("citas/{id:int}/nota")]
    [ProducesResponseType(201)]
    [Authorize(Roles = "professional")]
    public async Task<IActionResult> AddNote(int id, NotaInput input, CancellationToken ct)
    {
        await using var s = await Open(ct, ["professional"]);
        var cita = await s.CallCursorOneAsync(
            "SP_ConsultarCita",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idCita", id));
        var citaProf = Convert.ToInt32(cita["idProfesional"]!);
        Dictionary<string, object?> outRow;
        try
        {
            outRow = await s.CallOutAsync(
                "SP_CrearNotaClinica",
                2,
                ct,
                ("userName", s.Identity.NombreUsuario),
                ("idUsuario", s.Identity.Id),
                ("ip", s.ClientIp),
                ("idCita", id),
                ("contenido", input.Contenido.Trim()));
        }
        catch (DomainException ex) when (ex.Status == 400 && citaProf != s.Identity.ProfesionalId)
        {
            throw new DomainException(403, "Solo el profesional que atendio la cita puede registrar su nota clinica.");
        }
        var idNota = Convert.ToInt32(outRow["outidnotaclinica"]!);
        await s.CommitAsync(ct);
        return StatusCode(201, new
        {
            id = idNota,
            idCita = id,
            idProfesional = s.Identity.ProfesionalId,
            contenido = input.Contenido.Trim()
        });
    }

    [HttpGet("citas/{id:int}/nota")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "professional")]
    public async Task<IActionResult> Note(int id, CancellationToken ct)
    {
        await using var s = await Open(ct, ["professional"]);
        var row = await s.CallCursorOneAsync(
            "SP_ConsultarNotaClinica",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuario", s.Identity.Id),
            ("ip", s.ClientIp),
            ("idCita", id));
        await s.CommitAsync(ct);
        return Ok(row);
    }

    [HttpGet("agenda")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception,professional")]
    public async Task<IActionResult> Agenda(DateOnly fecha, int? profesionalId, CancellationToken ct)
    {
        await using var s = await Open(ct, ClinicRoles);
        if (fecha == default) throw new DomainException(400, "Fecha obligatoria.");
        if (s.Identity.Rol == "professional")
        {
            if (s.Identity.ProfesionalId is null) throw new DomainException(403, "Profesional no asociado.");
            if (profesionalId.HasValue) OwnProfessional(s, profesionalId.Value);
            profesionalId = s.Identity.ProfesionalId;
        }
        var rows = await s.CallCursorAsync(
            "SP_ConsultarAgendaDia",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("fecha", fecha),
            ("idProfesional", profesionalId));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpGet("estadisticas/citas")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin,reception")]
    public async Task<IActionResult> Statistics(DateOnly desde, DateOnly hasta, CancellationToken ct)
    {
        await using var s = await Open(ct, ReceptionRoles);
        ValidateRange(desde, hasta, 3660);
        var rows = await s.CallCursorAsync(
            "SP_ContarCitasPorEstado",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("fechaDesde", desde),
            ("fechaHasta", hasta));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    [HttpGet("auditoria")]
    [ProducesResponseType(200)]
    [Authorize(Roles = "clinic-admin")]
    public async Task<IActionResult> Audit(int? usuarioId, int? pacienteId, DateTimeOffset? desde, DateTimeOffset? hasta, CancellationToken ct)
    {
        await using var s = await Open(ct, AdminRoles);
        if (desde.HasValue && hasta.HasValue && desde > hasta) throw new DomainException(400, "Rango invalido.");
        var rows = await s.CallCursorAsync(
            "SP_ConsultarAuditoria",
            ct,
            ("userName", s.Identity.NombreUsuario),
            ("idUsuarioFiltro", usuarioId),
            ("idPacienteFiltro", pacienteId),
            ("fechaDesde", desde?.UtcDateTime),
            ("fechaHasta", hasta?.UtcDateTime));
        await s.CommitAsync(ct);
        return Ok(rows);
    }

    private static void ValidateRange(DateOnly start, DateOnly end, int maxDays)
    {
        if (start == default || end == default || end == DateOnly.MaxValue || end < start || end.DayNumber - start.DayNumber > maxDays)
            throw new DomainException(400, $"Rango invalido; maximo {maxDays} dias.");
    }
}
