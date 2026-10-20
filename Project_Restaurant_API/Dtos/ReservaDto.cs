using Project_Restaurant_API.Models;

namespace Project_Restaurant_API.Dtos;

/// <summary>Representación de salida de una reserva (respuesta de la API).</summary>
public class ReservaDto
{
    public int Id { get; set; }

    public string NombreCliente { get; set; } = string.Empty;

    public DateOnly Fecha { get; set; }

    public TimeOnly Hora { get; set; }

    public int CantidadPersonas { get; set; }

    public static ReservaDto Desde(Reserva r) => new()
    {
        Id = r.Id,
        NombreCliente = r.NombreCliente,
        Fecha = r.Fecha,
        Hora = r.Hora,
        CantidadPersonas = r.CantidadPersonas
    };
}
