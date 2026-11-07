using System.ComponentModel.DataAnnotations;
using System.Security.Claims;
using Microsoft.Extensions.Configuration;
using Project_Restaurant_API.Auth;
using Project_Restaurant_API.MediCitas;
using Xunit;

namespace Project_Restaurant_API.Tests.Unit;

public sealed class MedicalSecurityTests
{
    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("1")]
    [InlineData("{\"roles\":null}")]
    [InlineData("{\"roles\":[null,{},12]}")]
    [InlineData("{")]
    public async Task RolesMalformados_NoConcedenPermisos(string raw)
    {
        var identity = new ClaimsIdentity([new Claim("realm_access", raw)], "test");
        var principal = new ClaimsPrincipal(identity);
        await new KeycloakClaimsTransformation(new ConfigurationBuilder().Build()).TransformAsync(principal);
        Assert.Empty(identity.FindAll(identity.RoleClaimType));
    }

    [Fact]
    public async Task RolesDeOtroCliente_NoConcedenAcceso()
    {
        var identity = new ClaimsIdentity([new Claim("resource_access", "{\"otro-cliente\":{\"roles\":[\"api-writer\"]}}")], "test");
        var principal = new ClaimsPrincipal(identity);
        await new KeycloakClaimsTransformation(new ConfigurationBuilder().Build()).TransformAsync(principal);
        Assert.False(principal.IsInRole("api-writer"));
    }

    [Fact]
    public async Task RolesValidos_SeTransformanSinDuplicados()
    {
        var identity = new ClaimsIdentity([new Claim("realm_access", "{\"roles\":[\"reception\"]}")], "test");
        var principal = new ClaimsPrincipal(identity);
        var transform = new KeycloakClaimsTransformation(new ConfigurationBuilder().Build());
        await transform.TransformAsync(principal);
        await transform.TransformAsync(principal);
        Assert.True(principal.IsInRole("reception"));
        Assert.Single(identity.FindAll(identity.RoleClaimType));
    }

    [Fact]
    public void IntervalosContiguos_NoSeSolapan()
    {
        var start = DateTimeOffset.UtcNow;
        Assert.False(Availability.Overlaps(start, start.AddMinutes(30), start.AddMinutes(30), start.AddMinutes(60)));
        Assert.True(Availability.Overlaps(start, start.AddMinutes(30), start.AddMinutes(29), start.AddMinutes(60)));
    }

    [Theory]
    [InlineData("platform-admin", "app_plataforma")]
    [InlineData("clinic-admin", "app_admin_clinica")]
    [InlineData("reception", "app_recepcion")]
    [InlineData("professional", "app_profesional")]
    public void RolesDeAplicacion_MapeanARolesDeMenorPrivilegioEnPostgreSQL(string appRole, string expectedDbRole)
    {
        Assert.Equal(expectedDbRole, MedicalDatabase.MapDatabaseRole(appRole));
    }

    [Fact]
    public void RolDesconocido_LanzaExcepcion403AlMapearRolBD()
    {
        var ex = Assert.Throws<DomainException>(() => MedicalDatabase.MapDatabaseRole("desconocido"));
        Assert.Equal(403, ex.Status);
    }

    [Fact]
    public void EntradasDTO_ValidanRestriccionesDeDominio()
    {
        var validService = new ServicioInput("Consulta General", 30, "Medicina General");
        Assert.True(Validate(validService));

        var invalidService = new ServicioInput("Consulta", 0, "Medicina General");
        Assert.False(Validate(invalidService));

        var invalidSchedule = new HorarioInput(8, new TimeOnly(8, 0), new TimeOnly(12, 0));
        Assert.False(Validate(invalidSchedule));

        var invalidBooking = new CitaInput(0, 1, 1, DateTimeOffset.UtcNow);
        Assert.False(Validate(invalidBooking));
    }

    private static bool Validate(object model)
    {
        var context = new ValidationContext(model);
        var results = new List<ValidationResult>();
        return Validator.TryValidateObject(model, context, results, validateAllProperties: true);
    }
}
