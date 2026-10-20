using System.ComponentModel.DataAnnotations;
using Project_Restaurant_API.Models;

namespace Project_Restaurant_API.Dtos;

/// <summary>
/// Cuerpo de entrada para POST y PUT (mismos campos obligatorios).
///
/// La validación es declarativa: con [ApiController], ASP.NET devuelve 400
/// automáticamente antes de ejecutar la acción si falta un campo o está fuera de rango.
/// </summary>
public class ReservaInputDto
{
    [Required(ErrorMessage = "nombreCliente es obligatorio.")]
    [MaxLength(120, ErrorMessage = "nombreCliente no puede exceder 120 caracteres.")]
    public string? NombreCliente { get; set; }

    [Required(ErrorMessage = "fecha es obligatoria (formato yyyy-MM-dd).")]
    public DateOnly? Fecha { get; set; }

    [Required(ErrorMessage = "hora es obligatoria (formato HH:mm:ss).")]
    public TimeOnly? Hora { get; set; }

    [Required(ErrorMessage = "cantidadPersonas es obligatoria.")]
    [Range(1, 50, ErrorMessage = "cantidadPersonas debe estar entre 1 y 50.")]
    public int? CantidadPersonas { get; set; }

    /// <summary>
    /// Convierte a entidad. Seguro llamarlo dentro de la acción: [ApiController]
    /// ya garantizó que el modelo es válido.
    /// </summary>
    public Reserva AEntidad() => new()
    {
        NombreCliente = NombreCliente!.Trim(),
        Fecha = Fecha!.Value,
        Hora = Hora!.Value,
        CantidadPersonas = CantidadPersonas!.Value
    };

    public void AplicarA(Reserva reserva)
    {
        var datos = AEntidad();
        reserva.NombreCliente = datos.NombreCliente;
        reserva.Fecha = datos.Fecha;
        reserva.Hora = datos.Hora;
        reserva.CantidadPersonas = datos.CantidadPersonas;
    }
}
