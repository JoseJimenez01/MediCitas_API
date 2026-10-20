using Project_Restaurant_API.Dtos;
using Project_Restaurant_API.Models;
using Xunit;

namespace Project_Restaurant_API.Tests.Unit;

/// <summary>
/// Pruebas unitarias del mapeo DTO <-> entidad (vive dentro de los DTOs).
/// Aisladas: sin base de datos ni HTTP.
/// </summary>
public class ReservaMappingTests
{
    [Fact]
    public void AEntidad_CopiaLosCampos_YRecortaElNombre()
    {
        var dto = new ReservaInputDto
        {
            NombreCliente = "  Luis Perez  ",
            Fecha = new DateOnly(2026, 9, 1),
            Hora = new TimeOnly(13, 0),
            CantidadPersonas = 2
        };

        var entidad = dto.AEntidad();

        Assert.Equal("Luis Perez", entidad.NombreCliente);
        Assert.Equal(new DateOnly(2026, 9, 1), entidad.Fecha);
        Assert.Equal(new TimeOnly(13, 0), entidad.Hora);
        Assert.Equal(2, entidad.CantidadPersonas);
    }

    [Fact]
    public void AplicarA_ModificaLaEntidad_SinTocarElId()
    {
        var entidad = new Reserva
        {
            Id = 7,
            NombreCliente = "Original",
            Fecha = new DateOnly(2026, 1, 1),
            Hora = new TimeOnly(10, 0),
            CantidadPersonas = 1
        };

        new ReservaInputDto
        {
            NombreCliente = "Actualizado",
            Fecha = new DateOnly(2026, 12, 31),
            Hora = new TimeOnly(22, 0),
            CantidadPersonas = 8
        }.AplicarA(entidad);

        Assert.Equal(7, entidad.Id);
        Assert.Equal("Actualizado", entidad.NombreCliente);
        Assert.Equal(new DateOnly(2026, 12, 31), entidad.Fecha);
        Assert.Equal(new TimeOnly(22, 0), entidad.Hora);
        Assert.Equal(8, entidad.CantidadPersonas);
    }

    [Fact]
    public void Desde_CopiaTodosLosCamposIncluidoId()
    {
        var dto = ReservaDto.Desde(new Reserva
        {
            Id = 42,
            NombreCliente = "Maria Gomez",
            Fecha = new DateOnly(2026, 10, 5),
            Hora = new TimeOnly(20, 15),
            CantidadPersonas = 6
        });

        Assert.Equal(42, dto.Id);
        Assert.Equal("Maria Gomez", dto.NombreCliente);
        Assert.Equal(new DateOnly(2026, 10, 5), dto.Fecha);
        Assert.Equal(new TimeOnly(20, 15), dto.Hora);
        Assert.Equal(6, dto.CantidadPersonas);
    }
}
