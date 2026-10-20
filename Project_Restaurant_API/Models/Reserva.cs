namespace Project_Restaurant_API.Models
{
    /// <summary>
    /// Entidad de dominio: una reserva de mesa.
    /// Vive en la tabla "reservas" de PostgreSQL.
    /// </summary>
    public class Reserva
    {
        public int Id { get; set; }

        public string NombreCliente { get; set; } = string.Empty;

        public DateOnly Fecha { get; set; }

        public TimeOnly Hora { get; set; }

        public int CantidadPersonas { get; set; }
    }
}
