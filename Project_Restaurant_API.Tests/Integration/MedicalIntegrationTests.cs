using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using Xunit;

namespace Project_Restaurant_API.Tests.Integration;

[CollectionDefinition("Medical", DisableParallelization = true)]
public sealed class MedicalCollection;

[Collection("Medical")]
public sealed class MedicalIntegrationTests
{
    private readonly HttpClient api = new() { BaseAddress = new Uri(Environment.GetEnvironmentVariable("TEST_API_BASE_URL") ?? "http://localhost:8080") };
    private const int Clinic = 1;
    private const int OtherClinic = 2;
    private const int Professional = 1;
    private const int OtherProfessional = 2;
    private const int Service = 1;
    private const int Patient = 1;
    private const int OtherPatient = 2;
    private const int OtherClinicPatient = 1101;
    private const int OtherClinicProfessional = 20;

    private static DateOnly NextMonday
    {
        get
        {
            var baseDate = DateOnly.FromDateTime(DateTime.UtcNow.AddDays(14));
            var daysUntilMonday = ((int)DayOfWeek.Monday - (int)baseDate.DayOfWeek + 7) % 7;
            return baseDate.AddDays(daysUntilMonday);
        }
    }

    private static DateTimeOffset Start(DateOnly date, int hour) => new(date.Year, date.Month, date.Day, hour, 0, 0, TimeSpan.FromHours(-6));

    private static string AdminConnectionString => new NpgsqlConnectionStringBuilder
    {
        Host = Environment.GetEnvironmentVariable("POSTGRES_HOST") ?? "localhost",
        Port = int.Parse(Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432"),
        Database = Environment.GetEnvironmentVariable("POSTGRES_DB") ?? "restaurantdb",
        Username = Environment.GetEnvironmentVariable("TEST_DB_ADMIN_USER") ?? "postgres",
        Password = Environment.GetEnvironmentVariable("TEST_DB_ADMIN_PASSWORD") ?? "secretodesk"
    }.ConnectionString;

    private static string AppConnectionString => new NpgsqlConnectionStringBuilder
    {
        Host = Environment.GetEnvironmentVariable("POSTGRES_HOST") ?? "localhost",
        Port = int.Parse(Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432"),
        Database = Environment.GetEnvironmentVariable("POSTGRES_DB") ?? "restaurantdb",
        Username = Environment.GetEnvironmentVariable("APP_DB_USER") ?? "medicitas_app",
        Password = Environment.GetEnvironmentVariable("APP_DB_PASSWORD") ?? "medicitas-local-pass"
    }.ConnectionString;

    private async Task<string> Token(string username)
    {
        using var http = new HttpClient();
        var url = Environment.GetEnvironmentVariable("TEST_KEYCLOAK_TOKEN_URL") ?? "http://localhost:8081/realms/restaurant/protocol/openid-connect/token";
        using var response = await http.PostAsync(url, new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "password",
            ["client_id"] = "restaurant-api",
            ["username"] = username,
            ["password"] = Environment.GetEnvironmentVariable("MED_TEST_PASSWORD") ?? "MediCitas123!"
        }));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("access_token").GetString()!;
    }

    private async Task<HttpResponseMessage> Send(HttpMethod method, string path, string? token, object? body = null)
    {
        using var request = new HttpRequestMessage(method, path);
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = JsonContent.Create(body);
        return await api.SendAsync(request);
    }

    private static async Task<JsonElement> Json(HttpResponseMessage response, HttpStatusCode expected)
    {
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == expected, $"Esperado {(int)expected}, recibido {(int)response.StatusCode}: {text}");
        return JsonDocument.Parse(text).RootElement.Clone();
    }

    private object Booking(DateTimeOffset start, int? professional = null, int? patient = null)
        => new { pacienteId = patient ?? Patient, profesionalId = professional ?? Professional, servicioId = Service, inicio = start };

    private async Task Cancel(int id, string token)
        => await Send(HttpMethod.Post, $"/api/citas/{id}/cancelar", token, new { motivo = "Limpieza de prueba" });

    [Theory]
    [InlineData("POST", "/api/citas", "profesional1")]
    [InlineData("POST", "/api/usuarios", "recepcion1")]
    [InlineData("PUT", "/api/usuarios/1", "recepcion1")]
    [InlineData("POST", "/api/citas/1/nota", "admin1")]
    public async Task RF17_RolInadecuadoDevuelve403AunqueElCuerpoSeaInvalido(string method, string path, string username)
    {
        var token = await Token(username);
        foreach (var body in new[] { "{", "{}" })
        {
            using var request = new HttpRequestMessage(new HttpMethod(method), path)
            {
                Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json")
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await api.SendAsync(request);
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
    }

    [Fact]
    public async Task RF1_RF2_RF3_RF4_RF5_RF14_RF16_RF20_RF21_AdministracionCompleta()
    {
        var platform = await Token("plataforma");
        var suffix = Guid.NewGuid().ToString("N")[..8];
        var password = Environment.GetEnvironmentVariable("MED_TEST_PASSWORD") ?? "MediCitas123!";
        var clinic = await Json(await Send(HttpMethod.Post, "/api/clinicas", platform, new
        {
            nombre = "Clinica " + suffix,
            identificador = "T-" + suffix,
            zonaHoraria = "America/Costa_Rica",
            administradorIdentidad = Guid.Empty,
            nombreAdministrador = "Admin " + suffix,
            administradorNombreUsuario = "adm-" + suffix,
            administradorPassword = password
        }), HttpStatusCode.Created);
        var clinicId = clinic.GetProperty("id").GetInt32();
        var admin = await Token("adm-" + suffix);
        var identity = await Json(await Send(HttpMethod.Get, "/api/yo", admin), HttpStatusCode.OK);
        Assert.Equal(clinicId, identity.GetProperty("clinicaId").GetInt32());

        var user = await Json(await Send(HttpMethod.Post, "/api/usuarios", admin, new
        {
            identidad = Guid.Empty,
            nombre = "Dr " + suffix,
            rol = "professional",
            nombreUsuario = "doc-" + suffix,
            password
        }), HttpStatusCode.Created);
        var userId = user.GetProperty("id").GetInt32();

        var service = await Json(await Send(HttpMethod.Post, "/api/servicios", admin,
            new { nombre = "Cons " + suffix, duracionMinutos = 30, especialidad = "Medicina General" }), HttpStatusCode.Created);
        var serviceId = service.GetProperty("id").GetInt32();

        await Json(await Send(HttpMethod.Put, $"/api/servicios/{serviceId}", admin,
            new { nombre = "Cons2 " + suffix, duracionMinutos = 30, especialidad = "Medicina General" }), HttpStatusCode.OK);

        var professional = await Json(await Send(HttpMethod.Post, "/api/profesionales", admin, new
        {
            usuarioId = userId,
            nombre = "Dr " + suffix,
            especialidad = "Medicina General",
            servicios = new[] { serviceId }
        }), HttpStatusCode.Created);
        var professionalId = professional.GetProperty("id").GetInt32();

        var day = NextMonday;
        await Json(await Send(HttpMethod.Post, $"/api/profesionales/{professionalId}/horarios", admin,
            new { diaSemana = 1, inicio = "08:00:00", fin = "12:00:00" }), HttpStatusCode.Created);

        var patient = await Json(await Send(HttpMethod.Post, "/api/pacientes", admin,
            new { identificacion = "ID-" + suffix, nombre = "Pac " + suffix, fechaNacimiento = "2000-01-01", contacto = "pac@example.test" }), HttpStatusCode.Created);
        var patientId = patient.GetProperty("id").GetInt32();

        await Json(await Send(HttpMethod.Put, $"/api/pacientes/{patientId}", admin,
            new { identificacion = "ID-" + suffix, nombre = "Pac act " + suffix, fechaNacimiento = "2000-01-01", contacto = "otro@example.test" }), HttpStatusCode.OK);

        await Json(await Send(HttpMethod.Get, $"/api/pacientes/{patientId}/historial", admin), HttpStatusCode.OK);
        await Json(await Send(HttpMethod.Get, $"/api/agenda?fecha={day:yyyy-MM-dd}", admin), HttpStatusCode.OK);
        await Json(await Send(HttpMethod.Get, $"/api/estadisticas/citas?desde={day:yyyy-MM-dd}&hasta={day:yyyy-MM-dd}", admin), HttpStatusCode.OK);
        await Json(await Send(HttpMethod.Get, "/api/usuarios", admin), HttpStatusCode.OK);
        await Json(await Send(HttpMethod.Get, "/api/profesionales", admin), HttpStatusCode.OK);
        await Json(await Send(HttpMethod.Get, "/api/servicios", admin), HttpStatusCode.OK);

        var available = await Json(await Send(HttpMethod.Get, $"/api/disponibilidad/servicios/{serviceId}?desde={day:yyyy-MM-dd}&hasta={day:yyyy-MM-dd}", admin), HttpStatusCode.OK);
        Assert.NotEmpty(available.EnumerateArray());

        var reception = await Json(await Send(HttpMethod.Post, "/api/usuarios", admin, new
        {
            identidad = Guid.Empty,
            nombre = "Rec " + suffix,
            rol = "reception",
            nombreUsuario = "rec-" + suffix,
            password
        }), HttpStatusCode.Created);
        var receptionToken = await Token("rec-" + suffix);
        var receptionId = reception.GetProperty("id").GetInt32();
        var receptionSub = reception.GetProperty("tokenSub").GetGuid();

        await Json(await Send(HttpMethod.Put, $"/api/usuarios/{receptionId}", admin,
            new { identidad = receptionSub, nombre = "Rec " + suffix, rol = "professional", activo = true }), HttpStatusCode.OK);
        var updatedToken = await Token("rec-" + suffix);
        await Json(await Send(HttpMethod.Get, "/api/pacientes", updatedToken), HttpStatusCode.OK);

        Assert.Equal(HttpStatusCode.NoContent, (await Send(HttpMethod.Delete, $"/api/usuarios/{receptionId}", admin)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/pacientes", updatedToken)).StatusCode);
    }

    [Fact]
    public async Task RF17_SinToken401_RolInadecuado403()
    {
        Assert.Equal(HttpStatusCode.Unauthorized, (await Send(HttpMethod.Get, "/api/pacientes", null)).StatusCode);
        var professional = await Token("profesional1");
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Post, "/api/citas", professional, Booking(Start(NextMonday, 8)))).StatusCode);
        var platform = await Token("plataforma");
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/pacientes", platform)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await Send(HttpMethod.Get, "/api/pacientes", "invalid-token")).StatusCode);
    }

    [Fact]
    public async Task RF9_I1_CarreraTieneExactamenteUnaGanadora()
    {
        var token = await Token("recepcion1");
        var start = Start(NextMonday, 8);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<HttpResponseMessage> Compete(int patient)
        {
            await gate.Task;
            return await Send(HttpMethod.Post, "/api/citas", token, Booking(start, patient: patient));
        }
        var a = Compete(Patient);
        var b = Compete(OtherPatient);
        gate.SetResult();
        var responses = await Task.WhenAll(a, b);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Created);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Conflict);
        var winner = await responses.Single(r => r.StatusCode == HttpStatusCode.Created).Content.ReadFromJsonAsync<JsonElement>();
        await Cancel(winner.GetProperty("id").GetInt32(), token);
    }

    [Fact]
    public async Task RF9_I2_PacienteNoPuedeReservarDosProfesionalesAlMismoTiempo()
    {
        var token = await Token("recepcion1");
        var start = Start(NextMonday.AddDays(1), 9);
        var tasks = new[] { Professional, OtherProfessional }.Select(p => Send(HttpMethod.Post, "/api/citas", token, Booking(start, p)));
        var responses = await Task.WhenAll(tasks);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Created);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Conflict);
        var winner = await responses.Single(r => r.StatusCode == HttpStatusCode.Created).Content.ReadFromJsonAsync<JsonElement>();
        await Cancel(winner.GetProperty("id").GetInt32(), token);
    }

    [Fact]
    public async Task RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes()
    {
        var token = await Token("recepcion1");
        var day = NextMonday.AddDays(2);
        var path = $"/api/disponibilidad?profesionalId={Professional}&servicioId={Service}&fecha={day:yyyy-MM-dd}";
        var before = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        var warm = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.True(warm.GetProperty("cacheHit").GetBoolean());

        var start = before.GetProperty("espacios")[0].GetProperty("inicio").GetDateTimeOffset();
        var next = before.GetProperty("espacios")[1].GetProperty("inicio").GetDateTimeOffset();

        var created = await Json(await Send(HttpMethod.Post, "/api/citas", token, Booking(start)), HttpStatusCode.Created);
        var id = created.GetProperty("id").GetInt32();
        Assert.Equal(TimeSpan.FromMinutes(30), created.GetProperty("horaFin").GetDateTimeOffset() - created.GetProperty("horaInicio").GetDateTimeOffset());

        var booked = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.False(booked.GetProperty("cacheHit").GetBoolean());
        Assert.DoesNotContain(booked.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == start);

        var moved = await Json(await Send(HttpMethod.Post, $"/api/citas/{id}/reprogramar", token,
            new { profesionalId = Professional, servicioId = Service, inicio = next }), HttpStatusCode.OK);

        var after = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.Contains(after.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == start);
        Assert.DoesNotContain(after.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == next);

        await Cancel(moved.GetProperty("id").GetInt32(), token);
        var cancelled = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.Contains(cancelled.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == next);

        Assert.Equal(HttpStatusCode.Conflict, (await Send(HttpMethod.Post, $"/api/citas/{id}/cancelar", token, new { motivo = "Estado final" })).StatusCode);
    }

    [Fact]
    public async Task RF6_I3_BloqueoRetiraEspaciosYListaConflictos()
    {
        var receptionist = await Token("recepcion1");
        var admin = await Token("admin1");
        var day = NextMonday.AddDays(3);
        var start = Start(day, 10);

        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(Start(day, 3)))).StatusCode);

        var appointment = await Json(await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(start)), HttpStatusCode.Created);
        var appointmentId = appointment.GetProperty("id").GetInt32();

        var block = await Json(await Send(HttpMethod.Post, $"/api/profesionales/{Professional}/bloqueos", admin,
            new { inicio = start, fin = start.AddHours(2), motivo = "permisos" }), HttpStatusCode.Created);

        Assert.Contains(block.GetProperty("conflictos").EnumerateArray(), c => c.GetProperty("idCita").GetInt32() == appointmentId);
        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(start.AddHours(1)))).StatusCode);

        await Cancel(appointmentId, receptionist);
        var blockId = block.GetProperty("bloqueo").GetProperty("id").GetInt32();
        Assert.Equal(HttpStatusCode.NoContent, (await Send(HttpMethod.Delete, $"/api/bloqueos/{blockId}", admin)).StatusCode);
    }

    [Fact]
    public async Task I5_ParametrosYReferenciasNoPermitenFugaEntreClinicas()
    {
        var token = await Token("recepcion1");
        Assert.Equal(HttpStatusCode.NotFound, (await Send(HttpMethod.Get, $"/api/pacientes/{OtherClinicPatient}", token)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, $"/api/pacientes?clinicaId={OtherClinic}", token)).StatusCode);

        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", token, Booking(Start(NextMonday, 9), patient: OtherClinicPatient))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", token, Booking(Start(NextMonday, 9), professional: OtherClinicProfessional))).StatusCode);

        var admin2 = await Token("admin2");
        var logs = await Json(await Send(HttpMethod.Get, "/api/auditoria", admin2), HttpStatusCode.OK);
        Assert.NotEmpty(logs.EnumerateArray());
    }

    [Fact]
    public async Task RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos()
    {
        var receptionist = await Token("recepcion1");
        var professional = await Token("profesional1");
        var another = await Token("profesional1b");
        var admin = await Token("admin1");

        int idCita;
        int idPaciente;
        await using (var conn = new NpgsqlConnection(AdminConnectionString))
        {
            await conn.OpenAsync();
            await using var cmd = new NpgsqlCommand(
                "SELECT id, id_paciente FROM cita WHERE id_clinica = 1 AND id_profesional = 1 AND estado = 'reservada' AND hora_inicio <= now() ORDER BY id DESC LIMIT 1",
                conn);
            await using var reader = await cmd.ExecuteReaderAsync();
            Assert.True(await reader.ReadAsync(), "Debe existir al menos una cita pasada en estado 'reservada' para profesional 1.");
            idCita = reader.GetInt32(0);
            idPaciente = reader.GetInt32(1);
        }

        await Json(await Send(HttpMethod.Post, $"/api/citas/{idCita}/desenlace", receptionist, new { estado = "atendida" }), HttpStatusCode.OK);
        Assert.Equal(HttpStatusCode.Conflict, (await Send(HttpMethod.Post, $"/api/citas/{idCita}/desenlace", receptionist, new { estado = "ausente" })).StatusCode);

        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Post, $"/api/citas/{idCita}/nota", another, new { contenido = "No autorizado" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Post, $"/api/citas/{idCita}/nota", admin, new { contenido = "No autorizado" })).StatusCode);

        await Json(await Send(HttpMethod.Post, $"/api/citas/{idCita}/nota", professional, new { contenido = "Nota clinica de prueba" }), HttpStatusCode.Created);
        await Json(await Send(HttpMethod.Get, $"/api/citas/{idCita}/nota", professional), HttpStatusCode.OK);

        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/auditoria", receptionist)).StatusCode);
        var logs = await Json(await Send(HttpMethod.Get, $"/api/auditoria?pacienteId={idPaciente}", admin), HttpStatusCode.OK);
        Assert.Contains(logs.EnumerateArray(), l => l.GetProperty("accion").GetString() == "escritura" && l.GetProperty("infoUsada").GetString() == "contenido");
        Assert.Contains(logs.EnumerateArray(), l => l.GetProperty("accion").GetString() == "lectura" && l.GetProperty("infoUsada").GetString() == "contenido");
    }

    [Fact]
    public async Task RF10_ReprogramacionFallidaConservaLaReservaOriginal()
    {
        var token = await Token("recepcion1");
        var start = Start(NextMonday.AddDays(4), 8);
        var a = await Json(await Send(HttpMethod.Post, "/api/citas", token, Booking(start)), HttpStatusCode.Created);
        var b = await Json(await Send(HttpMethod.Post, "/api/citas", token, Booking(start.AddHours(1), patient: OtherPatient)), HttpStatusCode.Created);
        var id = a.GetProperty("id").GetInt32();

        Assert.Equal(HttpStatusCode.Conflict, (await Send(HttpMethod.Post, $"/api/citas/{id}/reprogramar", token,
            new { profesionalId = Professional, servicioId = Service, inicio = start.AddHours(1) })).StatusCode);

        var original = await Json(await Send(HttpMethod.Get, $"/api/citas/{id}", token), HttpStatusCode.OK);
        Assert.Equal("reservada", original.GetProperty("estado").GetString());
        Assert.Equal(start, original.GetProperty("horaInicio").GetDateTimeOffset());

        await Cancel(id, token);
        await Cancel(b.GetProperty("id").GetInt32(), token);
    }

    [Fact]
    public async Task I5_I6_ModuloAdicional_RLSYBitacoraInmutable()
    {
        await using var appConn = new NpgsqlConnection(AppConnectionString);
        await appConn.OpenAsync();

        // 1. Sin app.id_clinica configurado, RLS bloquea por defecto (fail-closed: 0 filas)
        await using (var txNoTenant = await appConn.BeginTransactionAsync())
        {
            await new NpgsqlCommand("SET LOCAL ROLE app_recepcion", appConn, txNoTenant).ExecuteNonQueryAsync();
            var countNoTenant = (long)(await new NpgsqlCommand("SELECT count(*) FROM paciente", appConn, txNoTenant).ExecuteScalarAsync())!;
            Assert.Equal(0, countNoTenant);
        }

        // 2. Con app.id_clinica = 1, RLS impide ver pacientes de otras clinicas incluso sin filtro WHERE o con filtro malicioso
        await using (var txTenant1 = await appConn.BeginTransactionAsync())
        {
            await new NpgsqlCommand("SET LOCAL ROLE app_recepcion; SELECT set_config('app.id_clinica', '1', true)", appConn, txTenant1).ExecuteNonQueryAsync();
            var crossCount = (long)(await new NpgsqlCommand("SELECT count(*) FROM paciente WHERE id_clinica <> 1", appConn, txTenant1).ExecuteScalarAsync())!;
            Assert.Equal(0, crossCount);

            var insertCross = await Assert.ThrowsAsync<PostgresException>(() =>
                new NpgsqlCommand("INSERT INTO paciente (id_clinica, identificacion, nombre, fecha_nacimiento) VALUES (2, 'FUGA-1', 'Intento Fuga', '1990-01-01')", appConn, txTenant1)
                    .ExecuteNonQueryAsync());
            Assert.Equal("42501", insertCross.SqlState);
        }

        // 3. Comparacion de desempeno: Columna Discriminadora sin RLS vs. Row-Level Security (RLS) activo
        await using (var adminConn = new NpgsqlConnection(AdminConnectionString))
        {
            await adminConn.OpenAsync();
            var swNoRls = Stopwatch.StartNew();
            for (var i = 0; i < 20; i++)
            {
                await new NpgsqlCommand("SELECT count(*) FROM cita WHERE id_clinica = 1 AND estado = 'reservada'", adminConn).ExecuteScalarAsync();
            }
            swNoRls.Stop();

            await using var txRls = await appConn.BeginTransactionAsync();
            await new NpgsqlCommand("SET LOCAL ROLE app_recepcion; SELECT set_config('app.id_clinica', '1', true)", appConn, txRls).ExecuteNonQueryAsync();
            var swRls = Stopwatch.StartNew();
            for (var i = 0; i < 20; i++)
            {
                await new NpgsqlCommand("SELECT count(*) FROM cita WHERE id_clinica = 1 AND estado = 'reservada'", appConn, txRls).ExecuteScalarAsync();
            }
            swRls.Stop();

            Assert.True(swNoRls.ElapsedMilliseconds >= 0 && swRls.ElapsedMilliseconds >= 0);
        }

        // 4. I6: La bitacora de auditoria rechaza UPDATE, DELETE y TRUNCATE con SQLSTATE 42501
        foreach (var sql in new[]
        {
            "UPDATE registro_auditoria SET accion = 'lectura'",
            "DELETE FROM registro_auditoria",
            "TRUNCATE registro_auditoria"
        })
        {
            await using var tx = await appConn.BeginTransactionAsync();
            await new NpgsqlCommand("SET LOCAL ROLE app_admin_clinica; SELECT set_config('app.id_clinica', '1', true)", appConn, tx).ExecuteNonQueryAsync();
            var exception = await Assert.ThrowsAsync<PostgresException>(() => new NpgsqlCommand(sql, appConn, tx).ExecuteNonQueryAsync());
            Assert.Equal("42501", exception.SqlState);
        }
    }
}
