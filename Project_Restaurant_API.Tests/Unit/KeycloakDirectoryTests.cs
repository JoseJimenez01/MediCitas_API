using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Project_Restaurant_API.MediCitas;
using Xunit;

namespace Project_Restaurant_API.Tests.Unit;

public sealed class KeycloakDirectoryTests
{
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => action(request, ct);
    }

    private static KeycloakDirectory Directory(HttpClient http)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["KEYCLOAK_AUTHORITY"] = "http://keycloak.test/realms/restaurant",
            ["MED_ADMIN_CLIENT_SECRET"] = "test-only-secret"
        }).Build();
        return new KeycloakDirectory(http, config, NullLogger<KeycloakDirectory>.Instance);
    }

    private static HttpResponseMessage Json(object body, HttpStatusCode status = HttpStatusCode.OK)
        => new(status) { Content = JsonContent.Create(body) };

    [Fact]
    public async Task TimeoutDelProveedor_Devuelve503()
    {
        using var http = new HttpClient(new Handler((_, _) => throw new TaskCanceledException("Timeout del proveedor")));
        var error = await Assert.ThrowsAsync<DomainException>(() => Directory(http).ChangeAsync(
            Guid.NewGuid(), "Usuario", "reception", true, null, null, CancellationToken.None));
        Assert.Equal(503, error.Status);
    }

    [Fact]
    public async Task ErrorTrasCrearIdentidad_EliminaLaIdentidadHuerfana()
    {
        Guid? created = null;
        Guid? deleted = null;
        using var http = new HttpClient(new Handler(async (request, _) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("/token")) return Json(new { access_token = "test-token" });
            if (request.Method == HttpMethod.Post && request.RequestUri.AbsolutePath.EndsWith("/users"))
            {
                var body = await request.Content!.ReadFromJsonAsync<JsonElement>();
                created = body.GetProperty("id").GetGuid();
                var response = new HttpResponseMessage(HttpStatusCode.Created);
                response.Headers.Location = new Uri($"http://keycloak.test/admin/realms/restaurant/users/{created}");
                return response;
            }
            if (request.Method == HttpMethod.Delete)
            {
                deleted = Guid.Parse(request.RequestUri.Segments.Last());
                return new HttpResponseMessage(HttpStatusCode.NoContent);
            }
            return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        }));
        var error = await Assert.ThrowsAsync<DomainException>(() => Directory(http).ChangeAsync(
            Guid.Empty, "Usuario", "reception", true, "nuevo", "test-password", CancellationToken.None));
        Assert.Equal(503, error.Status);
        Assert.NotNull(created);
        Assert.Equal(created, deleted);
    }

    [Fact]
    public async Task DatosRechazadosPorKeycloak_Devuelven400()
    {
        using var http = new HttpClient(new Handler((request, _) => Task.FromResult(
            request.RequestUri!.AbsolutePath.EndsWith("/token") ? Json(new { access_token = "test-token" })
                : new HttpResponseMessage(HttpStatusCode.BadRequest))));
        var error = await Assert.ThrowsAsync<DomainException>(() => Directory(http).ChangeAsync(
            Guid.Empty, "Usuario", "reception", true, "invalido", "test-password", CancellationToken.None));
        Assert.Equal(400, error.Status);
    }

    [Fact]
    public async Task CancelacionDeLaPeticion_NoImpideRestaurarLaIdentidad()
    {
        var id = Guid.NewGuid();
        var enabled = true;
        var assigned = new List<string> { "reception" };
        using var http = new HttpClient(new Handler(async (request, _) =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("/token")) return Json(new { access_token = "test-token" });
            if (path.EndsWith("/roles/professional")) return Json(new { id = "role-professional", name = "professional" });
            if (path.EndsWith("/role-mappings/realm"))
            {
                if (request.Method == HttpMethod.Get) return Json(assigned.Select(name => new { id = "role-" + name, name }));
                if (request.Method == HttpMethod.Delete) assigned.Clear();
                if (request.Method == HttpMethod.Post)
                {
                    var roles = await request.Content!.ReadFromJsonAsync<JsonElement>();
                    assigned.AddRange(roles.EnumerateArray().Select(r => r.GetProperty("name").GetString()!));
                }
                return new HttpResponseMessage(HttpStatusCode.NoContent);
            }
            if (path.EndsWith($"/users/{id}"))
            {
                if (request.Method == HttpMethod.Get) return Json(new { id, enabled });
                var body = await request.Content!.ReadFromJsonAsync<JsonElement>();
                enabled = body.GetProperty("enabled").GetBoolean();
                return new HttpResponseMessage(HttpStatusCode.NoContent);
            }
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }));
        using var cancellation = new CancellationTokenSource();
        var change = await Directory(http).ChangeAsync(id, "Usuario", "professional", false, null, null, cancellation.Token);
        Assert.False(enabled);
        Assert.Equal(new[] { "professional" }, assigned);
        cancellation.Cancel();
        await change.DisposeAsync();
        Assert.True(enabled);
        Assert.Equal(new[] { "reception" }, assigned);
    }
}
