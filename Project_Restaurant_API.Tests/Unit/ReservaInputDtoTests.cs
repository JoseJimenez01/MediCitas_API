using System.ComponentModel.DataAnnotations;
using Project_Restaurant_API.Dtos;
using Xunit;

namespace Project_Restaurant_API.Tests.Unit;

/// <summary>
/// Pruebas unitarias de la validación de la reserva.
/// Aisladas: usan DataAnnotations del DTO, sin base de datos ni HTTP.
/// </summary>
public class ReservaInputDtoTests
{
    private static ReservaInputDto DtoValido() => new()
    {
        NombreCliente = "Ana Rodriguez",
        Fecha = new DateOnly(2026, 8, 20),
        Hora = new TimeOnly(19, 30),
        CantidadPersonas = 4
    };

    /// <summary>Devuelve los mensajes de error de validación (vacío si es válido).</summary>
    private static List<string> Validar(ReservaInputDto dto)
    {
        var resultados = new List<ValidationResult>();
        Validator.TryValidateObject(dto, new ValidationContext(dto), resultados, true);
        return resultados.Select(r => r.ErrorMessage ?? "").ToList();
    }

    [Fact]
    public void DtoValido_NoTieneErrores() =>
        Assert.Empty(Validar(DtoValido()));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void NombreClienteInvalido_TieneError(string? nombre)
    {
        var dto = DtoValido();
        dto.NombreCliente = nombre;

        Assert.Contains(Validar(dto), e => e.Contains("nombreCliente"));
    }

    [Fact]
    public void NombreClienteDemasiadoLargo_TieneError()
    {
        var dto = DtoValido();
        dto.NombreCliente = new string('a', 121);

        Assert.Contains(Validar(dto), e => e.Contains("nombreCliente"));
    }

    [Fact]
    public void NombreClienteEnElLimite_EsValido()
    {
        var dto = DtoValido();
        dto.NombreCliente = new string('a', 120);

        Assert.Empty(Validar(dto));
    }

    [Fact]
    public void FechaNula_TieneError()
    {
        var dto = DtoValido();
        dto.Fecha = null;

        Assert.Contains(Validar(dto), e => e.Contains("fecha"));
    }

    [Fact]
    public void HoraNula_TieneError()
    {
        var dto = DtoValido();
        dto.Hora = null;

        Assert.Contains(Validar(dto), e => e.Contains("hora"));
    }

    [Fact]
    public void CantidadPersonasNula_TieneError()
    {
        var dto = DtoValido();
        dto.CantidadPersonas = null;

        Assert.Contains(Validar(dto), e => e.Contains("cantidadPersonas"));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(51)]
    public void CantidadPersonasFueraDeRango_TieneError(int cantidad)
    {
        var dto = DtoValido();
        dto.CantidadPersonas = cantidad;

        Assert.Contains(Validar(dto), e => e.Contains("cantidadPersonas"));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(50)]
    public void CantidadPersonasEnLosLimites_EsValido(int cantidad)
    {
        var dto = DtoValido();
        dto.CantidadPersonas = cantidad;

        Assert.Empty(Validar(dto));
    }

    [Fact]
    public void CuerpoVacio_AcumulaTodosLosErrores()
    {
        Assert.True(Validar(new ReservaInputDto()).Count >= 4);
    }
}
