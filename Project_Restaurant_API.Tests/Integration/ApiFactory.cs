namespace Project_Restaurant_API.Tests.Integration
{
    /// <summary>
    /// Proveedor del HttpClient y de la configuracion para las pruebas de integracion.
    ///
    /// Apunta a la API ya levantada por Docker Compose (pila real: app + PostgreSQL +
    /// Keycloak). La base URL se toma de TEST_API_BASE_URL, por defecto http://localhost:8080.
    /// </summary>
    public class ApiFactory
    {
        public TestConfig Config { get; } = new();

        public HttpClient CreateClient()
        {
            var client = new HttpClient
            {
                BaseAddress = new Uri(Config.ApiBaseUrl),
                Timeout = TimeSpan.FromSeconds(30)
            };
            return client;
        }
    }
}
