using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;

namespace Project_Restaurant_API.Auth;

public sealed class KeycloakClaimsTransformation(IConfiguration config) : IClaimsTransformation
{
    public Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        var identity = principal.Identities.FirstOrDefault(i => i.IsAuthenticated);
        if (identity is null) return Task.FromResult(principal);
        AddRoles(principal.FindFirst("realm_access")?.Value, null, identity);
        AddRoles(principal.FindFirst("resource_access")?.Value,
            config["KEYCLOAK_CLIENT_ID"] ?? "restaurant-api", identity);
        return Task.FromResult(principal);
    }

    private static void AddRoles(string? raw, string? client, ClaimsIdentity identity)
    {
        if (raw is null) return;
        try
        {
            using var document = JsonDocument.Parse(raw);
            var node = document.RootElement;
            if (node.ValueKind != JsonValueKind.Object) return;
            if (client is not null && !node.TryGetProperty(client, out node)) return;
            if (node.ValueKind != JsonValueKind.Object || !node.TryGetProperty("roles", out var roles) || roles.ValueKind != JsonValueKind.Array) return;
            foreach (var role in roles.EnumerateArray())
                if (role.ValueKind == JsonValueKind.String && role.GetString() is string value && !identity.HasClaim(identity.RoleClaimType, value))
                    identity.AddClaim(new Claim(identity.RoleClaimType, value));
        }
        catch (JsonException) { }
    }
}
