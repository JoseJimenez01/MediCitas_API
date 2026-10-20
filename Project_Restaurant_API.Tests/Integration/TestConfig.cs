namespace Project_Restaurant_API.Tests.Integration
{
    /// <summary>
    /// Configuracion de las pruebas de integracion, leida del entorno.
    ///
    /// El comando documentado en el README levanta la pila (app + PostgreSQL + Keycloak)
    /// y exporta estas variables antes de correr `dotnet test`.
    ///
    /// Los tokens se obtienen de Keycloak con "resource owner password credentials"
    /// (delegado por completo al proveedor; la app solo valida la firma).
    /// Hay dos identidades: una con el rol requerido (debe poder escribir) y otra sin el
    /// rol (debe recibir 403).
    /// </summary>
    public class TestConfig
    {
        // Base URL de la API dentro del stack.
        public string ApiBaseUrl { get; } =
            Environment.GetEnvironmentVariable("TEST_API_BASE_URL") ?? "http://localhost:8080";

        // Endpoint de token de Keycloak (.../protocol/openid-connect/token).
        public string TokenUrl { get; } =
            Environment.GetEnvironmentVariable("TEST_KEYCLOAK_TOKEN_URL")
            ?? "http://localhost:8081/realms/restaurant/protocol/openid-connect/token";

        // Cliente (confidencial) usado para pedir tokens.
        public string ClientId { get; } =
            Environment.GetEnvironmentVariable("TEST_CLIENT_ID") ?? "restaurant-api";

        public string ClientSecret { get; } =
            Environment.GetEnvironmentVariable("TEST_CLIENT_SECRET") ?? "";

        // Identidad CON el rol requerido.
        public string UsuarioConRol { get; } =
            Environment.GetEnvironmentVariable("TEST_USERNAME") ?? "escritor";
        public string PasswordConRol { get; } =
            Environment.GetEnvironmentVariable("TEST_PASSWORD") ?? "escritor-pass";

        // Identidad SIN el rol requerido.
        public string UsuarioSinRol { get; } =
            Environment.GetEnvironmentVariable("TEST_USERNAME_NOROLE") ?? "lector";
        public string PasswordSinRol { get; } =
            Environment.GetEnvironmentVariable("TEST_PASSWORD_NOROLE") ?? "lector-pass";

        private readonly HttpClient _http = new();

        public Task<string> ObtenerTokenConRolAsync() =>
            ObtenerTokenAsync(UsuarioConRol, PasswordConRol);

        public Task<string> ObtenerTokenSinRolAsync() =>
            ObtenerTokenAsync(UsuarioSinRol, PasswordSinRol);

        private async Task<string> ObtenerTokenAsync(string username, string password)
        {
            var form = new Dictionary<string, string>
            {
                ["grant_type"] = "password",
                ["client_id"] = ClientId,
                ["client_secret"] = ClientSecret,
                ["username"] = username,
                ["password"] = password
            };

            using var resp = await _http.PostAsync(TokenUrl, new FormUrlEncodedContent(form));
            var cuerpo = await resp.Content.ReadAsStringAsync();

            if (!resp.IsSuccessStatusCode)
            {
                throw new InvalidOperationException(
                    $"Keycloak no emitio token ({(int)resp.StatusCode}) para '{username}': {cuerpo}");
            }

            using var doc = System.Text.Json.JsonDocument.Parse(cuerpo);
            return doc.RootElement.GetProperty("access_token").GetString()
                ?? throw new InvalidOperationException("Keycloak no devolvio access_token.");
        }
    }
}
