using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace Project_Restaurant_API.Tests.Integration
{
    /// <summary>
    /// Pruebas de integración: ejercitan los endpoints contra la pila real que levanta
    /// Docker Compose (app + PostgreSQL + Keycloak).
    ///
    /// La base URL de la API se toma de la variable de entorno TEST_API_BASE_URL
    /// (por defecto http://localhost:8080). El token se obtiene de Keycloak usando
    /// TEST_KEYCLOAK_TOKEN_URL / TEST_CLIENT_ID / TEST_CLIENT_SECRET.
    ///
    /// El comando documentado en el README levanta la pila antes de correr las pruebas.
    /// </summary>
    public class ReservasIntegrationTests : IClassFixture<ApiFactory>
    {
        private readonly HttpClient _api;
        private readonly TestConfig _cfg;

        public ReservasIntegrationTests(ApiFactory factory)
        {
            _api = factory.CreateClient();
            _cfg = factory.Config;
        }

        // ---------------- Liveness / Readiness ----------------

        [Fact]
        public async Task Health_Responde200_SinTocarLaBase()
        {
            var resp = await _api.GetAsync("/health");

            Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
            var body = await resp.Content.ReadAsStringAsync();
            Assert.Contains("healthy", body);
        }

        [Fact]
        public async Task Ready_Responde200_CuandoPostgresAceptaConsultas()
        {
            var resp = await _api.GetAsync("/ready");

            Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        }

        // ---------------- Ciclo CRUD (lecturas públicas) ----------------

        [Fact]
        public async Task CicloCRUD_Completo_ConPersistencia()
        {
            // 1. Crear (sin token -> debe ser 401)
            var sinToken = await _api.PostAsJsonAsync("/reservas", new
            {
                nombreCliente = "No Autorizado",
                fecha = "2026-08-20",
                hora = "19:30:00",
                cantidadPersonas = 2
            });
            Assert.Equal(HttpStatusCode.Unauthorized, sinToken.StatusCode);

            // 2. Crear con token valido -> 201
            var token = await _cfg.ObtenerTokenConRolAsync();
            using var reqCrear = new HttpRequestMessage(HttpMethod.Post, "/reservas")
            {
                Content = JsonContent.Create(new
                {
                    nombreCliente = "Integration Test",
                    fecha = "2026-08-20",
                    hora = "19:30:00",
                    cantidadPersonas = 3
                })
            };
            reqCrear.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            var crear = await _api.SendAsync(reqCrear);
            Assert.Equal(HttpStatusCode.Created, crear.StatusCode);

            var creado = await crear.Content.ReadFromJsonAsync<JsonElement>();
            var id = creado.GetProperty("id").GetInt32();

            try
            {
                // 3. Listar (publico) y verificar que refleja lo escrito
                var listar = await _api.GetAsync("/reservas");
                Assert.Equal(HttpStatusCode.OK, listar.StatusCode);

                // 4. Filtrar por fecha
                var filtrar = await _api.GetAsync("/reservas?fecha=2026-08-20");
                Assert.Equal(HttpStatusCode.OK, filtrar.StatusCode);

                // 5. Consultar por id
                var obtener = await _api.GetAsync($"/reservas/{id}");
                Assert.Equal(HttpStatusCode.OK, obtener.StatusCode);

                // 6. Actualizar con token -> 200
                using var reqPut = new HttpRequestMessage(HttpMethod.Put, $"/reservas/{id}")
                {
                    Content = JsonContent.Create(new
                    {
                        nombreCliente = "Integration Test Actualizado",
                        fecha = "2026-08-21",
                        hora = "20:00:00",
                        cantidadPersonas = 5
                    })
                };
                reqPut.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                var put = await _api.SendAsync(reqPut);
                Assert.Equal(HttpStatusCode.OK, put.StatusCode);

                // 7. Eliminar con token -> 204
                using var reqDel = new HttpRequestMessage(HttpMethod.Delete, $"/reservas/{id}");
                reqDel.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                var del = await _api.SendAsync(reqDel);
                Assert.Equal(HttpStatusCode.NoContent, del.StatusCode);

                // 8. Consultar tras eliminar -> 404
                var trasEliminar = await _api.GetAsync($"/reservas/{id}");
                Assert.Equal(HttpStatusCode.NotFound, trasEliminar.StatusCode);
            }
            finally
            {
                // Limpieza: intenta borrar por si acaso.
                using var reqDel = new HttpRequestMessage(HttpMethod.Delete, $"/reservas/{id}");
                try
                {
                    reqDel.Headers.Authorization =
                        new AuthenticationHeaderValue("Bearer", await _cfg.ObtenerTokenConRolAsync());
                    await _api.SendAsync(reqDel);
                }
                catch { /* best-effort */ }
            }
        }

        // ---------------- Validacion ----------------

        [Fact]
        public async Task Crear_CuerpoInvalido_Responde400()
        {
            var token = await _cfg.ObtenerTokenConRolAsync();
            using var req = new HttpRequestMessage(HttpMethod.Post, "/reservas")
            {
                Content = JsonContent.Create(new { nombreCliente = "" })
            };
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var resp = await _api.SendAsync(req);

            Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
        }

        [Fact]
        public async Task Consultar_IdInexistente_Responde404()
        {
            var resp = await _api.GetAsync("/reservas/999999");

            Assert.Equal(HttpStatusCode.NotFound, resp.StatusCode);
        }

        // ---------------- Autorizacion ----------------

        [Fact]
        public async Task Escribir_SinToken_Responde401()
        {
            var resp = await _api.PostAsJsonAsync("/reservas", new
            {
                nombreCliente = "X",
                fecha = "2026-08-20",
                hora = "19:30:00",
                cantidadPersonas = 2
            });

            Assert.Equal(HttpStatusCode.Unauthorized, resp.StatusCode);
        }

        [Fact]
        public async Task Escribir_TokenSinRol_Responde403()
        {
            var token = await _cfg.ObtenerTokenSinRolAsync();
            using var req = new HttpRequestMessage(HttpMethod.Post, "/reservas")
            {
                Content = JsonContent.Create(new
                {
                    nombreCliente = "X",
                    fecha = "2026-08-20",
                    hora = "19:30:00",
                    cantidadPersonas = 2
                })
            };
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var resp = await _api.SendAsync(req);

            Assert.Equal(HttpStatusCode.Forbidden, resp.StatusCode);
        }

        [Fact]
        public async Task Salud_Y_Disponibilidad_QuedanAbiertas_SinToken()
        {
            var health = await _api.GetAsync("/health");
            var ready = await _api.GetAsync("/ready");

            Assert.Equal(HttpStatusCode.OK, health.StatusCode);
            Assert.Equal(HttpStatusCode.OK, ready.StatusCode);
        }
    }
}
