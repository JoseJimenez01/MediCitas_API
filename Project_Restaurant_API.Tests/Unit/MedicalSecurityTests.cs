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
}
