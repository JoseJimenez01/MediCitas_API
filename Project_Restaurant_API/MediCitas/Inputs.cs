using System.ComponentModel.DataAnnotations;

namespace Project_Restaurant_API.MediCitas;

public sealed record ClinicaInput(
    [property: Required, StringLength(32, MinimumLength = 1)] string Nombre,
    [property: Required, StringLength(32, MinimumLength = 1)] string Identificador,
    [property: Required, StringLength(32, MinimumLength = 1)] string ZonaHoraria,
    Guid AdministradorIdentidad = default,
    [property: Required, StringLength(128, MinimumLength = 1)] string NombreAdministrador = "",
    [property: StringLength(32)] string? CorreoAdministrador = null,
    [property: StringLength(80)] string? AdministradorNombreUsuario = null,
    [property: StringLength(200)] string? AdministradorPassword = null);

public sealed record UsuarioInput(
    Guid Identidad = default,
    [property: Required, StringLength(128, MinimumLength = 1)] string Nombre = "",
    [property: Required, RegularExpression("^(clinic-admin|reception|professional)$")] string Rol = "reception",
    bool Activo = true,
    [property: StringLength(32)] string? Correo = null,
    [property: StringLength(80)] string? NombreUsuario = null,
    [property: StringLength(200)] string? Password = null);

public sealed record ServicioInput(
    [property: Required, StringLength(16, MinimumLength = 1)] string Nombre,
    [property: Range(5, 480)] int DuracionMinutos,
    [property: StringLength(32)] string? Especialidad = null,
    int? IdEspecialidad = null,
    bool Activo = true);

public sealed record ProfesionalInput(
    [property: Range(1, int.MaxValue)] int UsuarioId,
    [property: StringLength(128)] string? Nombre = null,
    [property: StringLength(32)] string? Especialidad = null,
    int? IdEspecialidad = null,
    int[]? Servicios = null);

public sealed record HorarioInput([property: Range(1, 7)] int DiaSemana, TimeOnly Inicio, TimeOnly Fin);

public sealed record BloqueoInput(
    DateTimeOffset Inicio,
    DateTimeOffset Fin,
    [property: Required, StringLength(120, MinimumLength = 1)] string Motivo,
    int? ServicioId = null);

public sealed record PacienteInput(
    [property: Required, StringLength(16, MinimumLength = 1)] string Identificacion,
    [property: Required, StringLength(32, MinimumLength = 1)] string Nombre,
    DateOnly FechaNacimiento,
    [property: StringLength(120)] string? Contacto = null,
    [property: StringLength(20)] string? Telefono = null,
    [property: StringLength(32)] string? Correo = null);

public sealed record CitaInput(
    [property: Range(1, int.MaxValue)] int PacienteId,
    [property: Range(1, int.MaxValue)] int ProfesionalId,
    [property: Range(1, int.MaxValue)] int ServicioId,
    DateTimeOffset Inicio);

public sealed record ReprogramarInput(
    int? ProfesionalId,
    int? ServicioId,
    DateTimeOffset Inicio);

public sealed record MotivoInput([property: Required, StringLength(64, MinimumLength = 1)] string Motivo);

public sealed record DesenlaceInput([property: Required, RegularExpression("^(atendida|ausente)$")] string Estado);

public sealed record NotaInput([property: Required, StringLength(20000, MinimumLength = 1)] string Contenido);
