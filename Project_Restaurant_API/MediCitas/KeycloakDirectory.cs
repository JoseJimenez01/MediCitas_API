using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Project_Restaurant_API.MediCitas;

public sealed class IdentityChange(Guid id, Func<Task> rollback) : IAsyncDisposable
{
    public Guid Id { get; } = id;
    private bool accepted;
    public void Accept() => accepted = true;
    public async ValueTask DisposeAsync()
    {
        if (!accepted) await rollback();
    }
}

public sealed class KeycloakDirectory(HttpClient http, IConfiguration config, ILogger<KeycloakDirectory> logger)
{
    private static readonly string[] DomainRoles = ["platform-admin", "clinic-admin", "reception", "professional"];

    public async Task<IdentityChange> ChangeAsync(Guid id, string name, string role, bool active, string? username, string? password, CancellationToken ct)
    {
        var authority = config["KEYCLOAK_AUTHORITY"] ?? "http://auth:8080/realms/restaurant";
        var separator = authority.IndexOf("/realms/", StringComparison.Ordinal);
        if (separator < 0) throw new DomainException(503, "Configuracion del proveedor de identidad invalida.");
        var server = authority[..separator];
        var realm = authority[(separator + 8)..].Trim('/');
        var secret = config["MED_ADMIN_CLIENT_SECRET"];
        if (string.IsNullOrEmpty(secret)) throw new DomainException(503, "Cliente de administracion de identidades no configurado.");
        try
        {
            using var tokenResponse = await http.PostAsync($"{authority}/protocol/openid-connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "client_credentials", ["client_id"] = "medicitas-provisioning", ["client_secret"] = secret
            }), ct);
            if (!tokenResponse.IsSuccessStatusCode) throw new DomainException(503, "El proveedor no autorizo la administracion de identidades.");
            var tokenJson = await tokenResponse.Content.ReadFromJsonAsync<JsonElement>(ct);
            var token = tokenJson.GetProperty("access_token").GetString()!;
            var root = $"{server}/admin/realms/{Uri.EscapeDataString(realm)}/";

            async Task<JsonElement> Request(string path, HttpMethod method, object? body = null, bool compensating = false)
            {
                var requestToken = compensating ? CancellationToken.None : ct;
                using var request = new HttpRequestMessage(method, root + path);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                if (body is not null) request.Content = JsonContent.Create(body);
                using var response = await http.SendAsync(request, requestToken);
                if (response.StatusCode == HttpStatusCode.NotFound) throw new DomainException(400, "La identidad no existe en Keycloak.");
                if (response.StatusCode == HttpStatusCode.Conflict) throw new DomainException(409, "El nombre de usuario ya existe.");
                if (response.StatusCode == HttpStatusCode.BadRequest) throw new DomainException(400, "Datos de identidad invalidos para el proveedor.");
                if (!response.IsSuccessStatusCode) throw new DomainException(503, "No se pudo actualizar la identidad en el proveedor.");
                if (path == "users" && method == HttpMethod.Post && response.Headers.Location is Uri location &&
                    Guid.TryParse(location.OriginalString.TrimEnd('/').Split('/').Last(), out var createdId)) id = createdId;
                var text = await response.Content.ReadAsStringAsync(requestToken);
                if (string.IsNullOrWhiteSpace(text)) return default;
                using var document = JsonDocument.Parse(text);
                return document.RootElement.Clone();
            }

            var created = id == Guid.Empty;
            IdentityChange? change = null;
            if (created)
            {
                if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password) || password.Length < 8)
                    throw new DomainException(400, "Nombre de usuario y password de al menos ocho caracteres son obligatorios.");
                id = Guid.NewGuid();
                await Request("users", HttpMethod.Post, new
                {
                    id, username = username.Trim(), enabled = active, firstName = name.Trim(), lastName = "MediCitas",
                    email = username.Trim() + "@example.test", emailVerified = true,
                    credentials = new[] { new { type = "password", value = password, temporary = false } }
                });
                change = new IdentityChange(id, async () =>
                {
                    try { await Request($"users/{id}", HttpMethod.Delete, compensating: true); }
                    catch (Exception ex) { logger.LogError("No se pudo compensar la identidad {Id}: {Type}", id, ex.GetType().Name); }
                });
            }
            try
            {
                var before = await Request($"users/{id}", HttpMethod.Get);
                var rolesBefore = (await Request($"users/{id}/role-mappings/realm", HttpMethod.Get)).EnumerateArray()
                    .Where(r => DomainRoles.Contains(r.GetProperty("name").GetString())).ToArray();
                change ??= new IdentityChange(id, async () =>
                {
                    try
                    {
                        await Request($"users/{id}", HttpMethod.Put, new { enabled = before.GetProperty("enabled").GetBoolean() }, compensating: true);
                        var assigned = (await Request($"users/{id}/role-mappings/realm", HttpMethod.Get, compensating: true)).EnumerateArray()
                            .Where(r => DomainRoles.Contains(r.GetProperty("name").GetString())).ToArray();
                        if (assigned.Length > 0) await Request($"users/{id}/role-mappings/realm", HttpMethod.Delete, assigned, compensating: true);
                        if (rolesBefore.Length > 0) await Request($"users/{id}/role-mappings/realm", HttpMethod.Post, rolesBefore, compensating: true);
                    }
                    catch (Exception ex) { logger.LogError("No se pudo compensar la identidad {Id}: {Type}", id, ex.GetType().Name); }
                });
                await Request($"users/{id}", HttpMethod.Put, new { enabled = active });
                if (rolesBefore.Length > 0) await Request($"users/{id}/role-mappings/realm", HttpMethod.Delete, rolesBefore);
                var wanted = await Request("roles/" + Uri.EscapeDataString(role), HttpMethod.Get);
                await Request($"users/{id}/role-mappings/realm", HttpMethod.Post, new[] { wanted });
                return change;
            }
            catch
            {
                if (change is not null) await change.DisposeAsync();
                throw;
            }
        }
        catch (HttpRequestException) { throw new DomainException(503, "Proveedor de identidad temporalmente no disponible."); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new DomainException(503, "El proveedor de identidad no respondio a tiempo.");
        }
    }
}
