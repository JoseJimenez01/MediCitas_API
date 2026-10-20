using System.ComponentModel.DataAnnotations;

namespace Project_Restaurant_API.MediCitas;

public sealed record ClinicaInput(
    [Required, StringLength(160, MinimumLength = 1)] string Nombre,
    [Required, StringLength(80, MinimumLength = 1)] string Identificador,
    [Required, StringLength(80)] string ZonaHoraria,
    Guid AdministradorIdentidad,
    [Required, StringLength(160, MinimumLength = 1)] string NombreAdministrador,
    [StringLength(80)] string? AdministradorNombreUsuario = null,
    [StringLength(200)] string? AdministradorPassword = null);

public sealed record UsuarioInput(Guid Identidad,
    [Required, StringLength(160, MinimumLength = 1)] string Nombre,
    [Required, RegularExpression("^(clinic-admin|reception|professional)$")] string Rol,
    bool Activo = true,
    [StringLength(80)] string? NombreUsuario = null,
    [StringLength(200)] string? Password = null);

public sealed record ServicioInput(
    [Required, StringLength(160, MinimumLength = 1)] string Nombre,
    [Range(5, 480)] int DuracionMinutos,
    [Required, StringLength(100, MinimumLength = 1)] string Especialidad,
    bool Activo = true);

public sealed record ProfesionalInput(Guid UsuarioId,
    [Required, StringLength(160, MinimumLength = 1)] string Nombre,
    [Required, StringLength(100, MinimumLength = 1)] string Especialidad,
    [Required] Guid[] Servicios);

public sealed record HorarioInput([Range(1, 7)] int DiaSemana, TimeOnly Inicio, TimeOnly Fin);

public sealed record BloqueoInput(DateTimeOffset Inicio, DateTimeOffset Fin,
    [Required, StringLength(300, MinimumLength = 1)] string Motivo);

public sealed record PacienteInput(
    [Required, StringLength(80, MinimumLength = 1)] string Identificacion,
    [Required, StringLength(160, MinimumLength = 1)] string Nombre,
    DateOnly FechaNacimiento,
    [Required, StringLength(300, MinimumLength = 1)] string Contacto);

public sealed record CitaInput(Guid PacienteId, Guid ProfesionalId, Guid ServicioId, DateTimeOffset Inicio);
public sealed record ReprogramarInput(Guid ProfesionalId, Guid ServicioId, DateTimeOffset Inicio);
public sealed record MotivoInput([Required, StringLength(300, MinimumLength = 1)] string Motivo);
public sealed record DesenlaceInput([Required, RegularExpression("^(atendida|ausente)$")] string Estado);
public sealed record NotaInput([Required, StringLength(20000, MinimumLength = 1)] string Contenido);
