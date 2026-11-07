using System.ComponentModel.DataAnnotations;

namespace Project_Restaurant_API.MediCitas;

public sealed record ClinicaInput(
    [Required, StringLength(32, MinimumLength = 1)] string Nombre,
    [Required, StringLength(32, MinimumLength = 1)] string Identificador,
    [Required, StringLength(32, MinimumLength = 1)] string ZonaHoraria,
    Guid AdministradorIdentidad = default,
    [Required, StringLength(128, MinimumLength = 1)] string NombreAdministrador = "",
    [StringLength(32)] string? CorreoAdministrador = null,
    [StringLength(80)] string? AdministradorNombreUsuario = null,
    [StringLength(200)] string? AdministradorPassword = null);

public sealed record UsuarioInput(
    Guid Identidad = default,
    [Required, StringLength(128, MinimumLength = 1)] string Nombre = "",
    [Required, RegularExpression("^(clinic-admin|reception|professional)$")] string Rol = "reception",
    bool Activo = true,
    [StringLength(32)] string? Correo = null,
    [StringLength(80)] string? NombreUsuario = null,
    [StringLength(200)] string? Password = null);

public sealed record ServicioInput(
    [Required, StringLength(16, MinimumLength = 1)] string Nombre,
    [Range(5, 480)] int DuracionMinutos,
    [StringLength(32)] string? Especialidad = null,
    int? IdEspecialidad = null,
    bool Activo = true);

public sealed record ProfesionalInput(
    [Range(1, int.MaxValue)] int UsuarioId,
    [StringLength(128)] string? Nombre = null,
    [StringLength(32)] string? Especialidad = null,
    int? IdEspecialidad = null,
    int[]? Servicios = null);

public sealed record HorarioInput([Range(1, 7)] int DiaSemana, TimeOnly Inicio, TimeOnly Fin);

public sealed record BloqueoInput(
    DateTimeOffset Inicio,
    DateTimeOffset Fin,
    [Required, StringLength(120, MinimumLength = 1)] string Motivo,
    int? ServicioId = null);

public sealed record PacienteInput(
    [Required, StringLength(16, MinimumLength = 1)] string Identificacion,
    [Required, StringLength(32, MinimumLength = 1)] string Nombre,
    DateOnly FechaNacimiento,
    [StringLength(120)] string? Contacto = null,
    [StringLength(20)] string? Telefono = null,
    [StringLength(32)] string? Correo = null);

public sealed record CitaInput(
    [Range(1, int.MaxValue)] int PacienteId,
    [Range(1, int.MaxValue)] int ProfesionalId,
    [Range(1, int.MaxValue)] int ServicioId,
    DateTimeOffset Inicio);

public sealed record ReprogramarInput(
    int? ProfesionalId,
    int? ServicioId,
    DateTimeOffset Inicio);

public sealed record MotivoInput([Required, StringLength(64, MinimumLength = 1)] string Motivo);

public sealed record DesenlaceInput([Required, RegularExpression("^(atendida|ausente)$")] string Estado);

public sealed record NotaInput([Required, StringLength(20000, MinimumLength = 1)] string Contenido);
