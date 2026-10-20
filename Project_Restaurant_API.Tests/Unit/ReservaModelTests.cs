using Project_Restaurant_API.Dtos;
using Project_Restaurant_API.Models;
using Xunit;

namespace Project_Restaurant_API.Tests.Unit;

/// <summary>
/// Pruebas del modelo de datos y de los valores por defecto del DTO.
/// Sin dependencias externas.
/// </summary>
public class ReservaModelTests
{
    [Fact]
    public void Reserva_AlmacenaTodosLosCampos()
    {
        var r = new Reserva
        {
            Id = 7,
            NombreCliente = "Carlos",
            Fecha = new DateOnly(2026, 3, 15),
            Hora = new TimeOnly(18, 45),
            CantidadPersonas = 5
        };

        Assert.Equal(7, r.Id);
        Assert.Equal("Carlos", r.NombreCliente);
        Assert.Equal(new DateOnly(2026, 3, 15), r.Fecha);
        Assert.Equal(new TimeOnly(18, 45), r.Hora);
        Assert.Equal(5, r.CantidadPersonas);
    }

    [Fact]
    public void ReservaInputDto_LasPropiedadesSonAnulablesPorDefecto()
    {
        var dto = new ReservaInputDto();

        Assert.Null(dto.NombreCliente);
        Assert.Null(dto.Fecha);
        Assert.Null(dto.Hora);
        Assert.Null(dto.CantidadPersonas);
    }
}
