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
    private static Guid Id(char prefix, int number) => Guid.Parse($"{prefix}0000000-0000-0000-0000-{number:000000000000}");
    private static readonly Guid Clinic = Id('1', 1);
    private static readonly Guid Professional = Id('3', 101);
    private static readonly Guid OtherProfessional = Id('3', 102);
    private static readonly Guid Service = Id('4', 101);
    private static readonly Guid Patient = Id('5', 101);
    private static DateOnly Day => DateOnly.FromDateTime(DateTime.UtcNow.AddDays(20));
    private static DateTimeOffset Start(DateOnly date, int hour) => new(date.Year, date.Month, date.Day, hour, 0, 0, TimeSpan.FromHours(-6));

    private async Task<string> Token(string username)
    {
        using var http = new HttpClient();
        var url = Environment.GetEnvironmentVariable("TEST_KEYCLOAK_TOKEN_URL") ?? "http://localhost:8081/realms/restaurant/protocol/openid-connect/token";
        using var response = await http.PostAsync(url, new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "password", ["client_id"] = "restaurant-api", ["username"] = username,
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

    private object Booking(DateTimeOffset start, Guid? professional = null, Guid? patient = null)
        => new { pacienteId = patient ?? Patient, profesionalId = professional ?? Professional, servicioId = Service, inicio = start };

    private async Task Cancel(Guid id, string token)
        => await Send(HttpMethod.Post, $"/api/citas/{id}/cancelar", token, new { motivo = "Limpieza de prueba" });

    [Theory]
    [InlineData("POST", "/api/citas", "profesional1")]
    [InlineData("POST", "/api/usuarios", "recepcion1")]
    [InlineData("PUT", "/api/usuarios/20000000-0000-0000-0000-000000000101", "recepcion1")]
    [InlineData("POST", "/api/citas/70000000-0000-0000-0000-000000000101/nota", "admin1")]
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
        var suffix = Guid.NewGuid().ToString("N")[..10];
        var password = Environment.GetEnvironmentVariable("MED_TEST_PASSWORD") ?? "MediCitas123!";
        var clinic = await Json(await Send(HttpMethod.Post, "/api/clinicas", platform, new
        {
            nombre = "Clinica de prueba", identificador = "TEST-" + suffix, zonaHoraria = "America/Costa_Rica",
            administradorIdentidad = Guid.Empty, nombreAdministrador = "Administracion de prueba",
            administradorNombreUsuario = "admin-" + suffix, administradorPassword = password
        }), HttpStatusCode.Created);
        var admin = await Token("admin-" + suffix);
        var identity = await Json(await Send(HttpMethod.Get, "/api/yo", admin), HttpStatusCode.OK);
        Assert.Equal(clinic.GetProperty("id").GetGuid(), identity.GetProperty("clinicaId").GetGuid());
        var user = await Json(await Send(HttpMethod.Post, "/api/usuarios", admin, new
        {
            identidad = Guid.Empty, nombre = "Profesional de prueba", rol = "professional", nombreUsuario = "doctor-" + suffix, password
        }), HttpStatusCode.Created);
        var service = await Json(await Send(HttpMethod.Post, "/api/servicios", admin,
            new { nombre = "Consulta", duracionMinutos = 30, especialidad = "Medicina de prueba" }), HttpStatusCode.Created);
        var serviceId = service.GetProperty("id").GetGuid();
        await Json(await Send(HttpMethod.Put, $"/api/servicios/{serviceId}", admin,
            new { nombre = "Consulta actualizada", duracionMinutos = 45, especialidad = "Medicina de prueba" }), HttpStatusCode.OK);
        var professional = await Json(await Send(HttpMethod.Post, "/api/profesionales", admin, new
        {
            usuarioId = user.GetProperty("id").GetGuid(), nombre = "Profesional de prueba", especialidad = "Medicina de prueba", servicios = new[] { serviceId }
        }), HttpStatusCode.Created);
        var day = Day;
        await Json(await Send(HttpMethod.Post, $"/api/profesionales/{professional.GetProperty("id").GetGuid()}/horarios", admin,
            new { diaSemana = day.DayOfWeek == DayOfWeek.Sunday ? 7 : (int)day.DayOfWeek, inicio = "08:00:00", fin = "12:00:00" }), HttpStatusCode.Created);
        var patient = await Json(await Send(HttpMethod.Post, "/api/pacientes", admin,
            new { identificacion = suffix, nombre = "Paciente", fechaNacimiento = "2000-01-01", contacto = "paciente@example.test" }), HttpStatusCode.Created);
        var patientId = patient.GetProperty("id").GetGuid();
        await Json(await Send(HttpMethod.Put, $"/api/pacientes/{patientId}", admin,
            new { identificacion = suffix, nombre = "Paciente actualizado", fechaNacimiento = "2000-01-01", contacto = "otro@example.test" }), HttpStatusCode.OK);
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
            identidad = Guid.Empty, nombre = "Recepcion de prueba", rol = "reception", nombreUsuario = "reception-" + suffix, password
        }), HttpStatusCode.Created);
        var receptionToken = await Token("reception-" + suffix);
        var receptionId = reception.GetProperty("id").GetGuid();
        await Json(await Send(HttpMethod.Put, $"/api/usuarios/{receptionId}", admin,
            new { identidad = receptionId, nombre = "Profesional sin agenda", rol = "professional", activo = true }), HttpStatusCode.OK);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/pacientes", receptionToken)).StatusCode);
        var updatedToken = await Token("reception-" + suffix);
        await Json(await Send(HttpMethod.Get, "/api/pacientes", updatedToken), HttpStatusCode.OK);
        Assert.Equal(HttpStatusCode.NoContent, (await Send(HttpMethod.Delete, $"/api/usuarios/{receptionId}", admin)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/pacientes", updatedToken)).StatusCode);
    }

    [Fact]
    public async Task ModuloAdicional_DetectaManipulacionDeBitacora()
    {
        var admin = await Token("admin1");
        await Json(await Send(HttpMethod.Get, $"/api/pacientes/{Patient}", admin), HttpStatusCode.OK);
        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = Environment.GetEnvironmentVariable("POSTGRES_HOST") ?? "bd",
            Port = int.Parse(Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432"),
            Database = Environment.GetEnvironmentVariable("POSTGRES_DB") ?? "restaurantdb",
            Username = Environment.GetEnvironmentVariable("TEST_DB_ADMIN_USER") ?? "postgres",
            Password = Environment.GetEnvironmentVariable("TEST_DB_ADMIN_PASSWORD") ?? ""
        };
        await using var conn = new NpgsqlConnection(builder.ConnectionString);
        await conn.OpenAsync();
        await using var original = new NpgsqlCommand($"SELECT id, accion FROM med.auditoria WHERE clinica_id = '{Clinic}' ORDER BY id LIMIT 1", conn);
        long id;
        string action;
        await using (var reader = await original.ExecuteReaderAsync())
        {
            Assert.True(await reader.ReadAsync());
            id = reader.GetInt64(0);
            action = reader.GetString(1);
        }
        try
        {
            await new NpgsqlCommand($"UPDATE med.auditoria SET accion = 'manipulada' WHERE id = {id}", conn).ExecuteNonQueryAsync();
            var check = await Json(await Send(HttpMethod.Get, "/api/auditoria/verificar", admin), HttpStatusCode.OK);
            Assert.False(check.GetProperty("valida").GetBoolean());
        }
        finally
        {
            await using var restore = new NpgsqlCommand("UPDATE med.auditoria SET accion = @action WHERE id = @id", conn);
            restore.Parameters.AddWithValue("action", action);
            restore.Parameters.AddWithValue("id", id);
            await restore.ExecuteNonQueryAsync();
        }
        var restored = await Json(await Send(HttpMethod.Get, "/api/auditoria/verificar", admin), HttpStatusCode.OK);
        Assert.True(restored.GetProperty("valida").GetBoolean());
    }

    [Fact]
    public async Task RF17_SinToken401_RolInadecuado403()
    {
        Assert.Equal(HttpStatusCode.Unauthorized, (await Send(HttpMethod.Get, "/api/pacientes", null)).StatusCode);
        var professional = await Token("profesional1");
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Post, "/api/citas", professional, Booking(Start(Day, 8)))).StatusCode);
        var platform = await Token("plataforma");
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/pacientes", platform)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await Send(HttpMethod.Get, "/api/pacientes", "invalid-token")).StatusCode);
    }

    [Fact]
    public async Task RF9_I1_CarreraTieneExactamenteUnaGanadora()
    {
        var token = await Token("recepcion1");
        var start = Start(Day.AddDays(1), 8);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<HttpResponseMessage> Compete(Guid patient)
        {
            await gate.Task;
            return await Send(HttpMethod.Post, "/api/citas", token, Booking(start, patient: patient));
        }
        var a = Compete(Patient);
        var b = Compete(Id('5', 102));
        gate.SetResult();
        var responses = await Task.WhenAll(a, b);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Created);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Conflict);
        var winner = await responses.Single(r => r.StatusCode == HttpStatusCode.Created).Content.ReadFromJsonAsync<JsonElement>();
        await Cancel(winner.GetProperty("id").GetGuid(), token);
    }

    [Fact]
    public async Task RF9_I2_PacienteNoPuedeReservarDosProfesionalesAlMismoTiempo()
    {
        var token = await Token("recepcion1");
        var tasks = new[] { Professional, OtherProfessional }.Select(p => Send(HttpMethod.Post, "/api/citas", token, Booking(Start(Day.AddDays(2), 9), p)));
        var responses = await Task.WhenAll(tasks);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Created);
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Conflict);
        var winner = await responses.Single(r => r.StatusCode == HttpStatusCode.Created).Content.ReadFromJsonAsync<JsonElement>();
        await Cancel(winner.GetProperty("id").GetGuid(), token);
    }

    [Fact]
    public async Task RF7_RF9_RF10_RF11_I4_I7_I8_CacheYReprogramacionSonCoherentes()
    {
        var token = await Token("recepcion1");
        var day = Day.AddDays(3);
        var path = $"/api/disponibilidad?profesionalId={Professional}&servicioId={Service}&fecha={day:yyyy-MM-dd}";
        var before = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        var warm = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.True(warm.GetProperty("cacheHit").GetBoolean());
        var start = before.GetProperty("espacios")[0].GetProperty("inicio").GetDateTimeOffset();
        var next = before.GetProperty("espacios")[1].GetProperty("inicio").GetDateTimeOffset();
        var created = await Json(await Send(HttpMethod.Post, "/api/citas", token, Booking(start)), HttpStatusCode.Created);
        var id = created.GetProperty("id").GetGuid();
        Assert.Equal(TimeSpan.FromMinutes(30), created.GetProperty("fin").GetDateTimeOffset() - created.GetProperty("inicio").GetDateTimeOffset());
        var booked = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.True(booked.GetProperty("version").GetInt64() > before.GetProperty("version").GetInt64());
        Assert.DoesNotContain(booked.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == start);
        var moved = await Json(await Send(HttpMethod.Post, $"/api/citas/{id}/reprogramar", token,
            new { profesionalId = Professional, servicioId = Service, inicio = next }), HttpStatusCode.OK);
        var after = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.Contains(after.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == start);
        Assert.DoesNotContain(after.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == next);
        await Cancel(moved.GetProperty("id").GetGuid(), token);
        var cancelled = await Json(await Send(HttpMethod.Get, path, token), HttpStatusCode.OK);
        Assert.Contains(cancelled.GetProperty("espacios").EnumerateArray(), x => x.GetProperty("inicio").GetDateTimeOffset() == next);
        Assert.Equal(HttpStatusCode.Conflict, (await Send(HttpMethod.Post, $"/api/citas/{id}/cancelar", token, new { motivo = "Estado final" })).StatusCode);
    }

    [Fact]
    public async Task RF6_I3_BloqueoRetiraEspaciosYListaConflictos()
    {
        var receptionist = await Token("recepcion1");
        var admin = await Token("admin1");
        var start = Start(Day.AddDays(4), 10);
        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(Start(Day.AddDays(4), 3)))).StatusCode);
        var appointment = await Json(await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(start)), HttpStatusCode.Created);
        var block = await Json(await Send(HttpMethod.Post, $"/api/profesionales/{Professional}/bloqueos", admin,
            new { inicio = start, fin = start.AddHours(2), motivo = "Permiso de prueba" }), HttpStatusCode.Created);
        Assert.Contains(block.GetProperty("conflictos").EnumerateArray(), c => c.GetProperty("id").GetGuid() == appointment.GetProperty("id").GetGuid());
        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(start.AddHours(1)))).StatusCode);
        await Cancel(appointment.GetProperty("id").GetGuid(), receptionist);
        Assert.Equal(HttpStatusCode.NoContent, (await Send(HttpMethod.Delete, $"/api/bloqueos/{block.GetProperty("bloqueo").GetProperty("id").GetGuid()}", admin)).StatusCode);
    }

    [Fact]
    public async Task I5_ParametrosYReferenciasNoPermitenFugaEntreClinicas()
    {
        var token = await Token("recepcion1");
        Assert.Equal(HttpStatusCode.NotFound, (await Send(HttpMethod.Get, $"/api/pacientes/{Id('5', 201)}", token)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, $"/api/pacientes?clinicaId={Id('1', 2)}", token)).StatusCode);
        var list = await Json(await Send(HttpMethod.Get, "/api/pacientes", token), HttpStatusCode.OK);
        Assert.All(list.EnumerateArray(), p => Assert.Equal(Clinic, p.GetProperty("clinicaId").GetGuid()));
        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", token, Booking(Start(Day, 9), patient: Id('5', 201)))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Send(HttpMethod.Post, "/api/citas", token, Booking(Start(Day, 9), Id('3', 201)))).StatusCode);
        var admin2 = await Token("admin2");
        var logs = await Json(await Send(HttpMethod.Get, "/api/auditoria", admin2), HttpStatusCode.OK);
        Assert.All(logs.EnumerateArray(), a => Assert.Equal(Id('1', 2), a.GetProperty("clinicaId").GetGuid()));
    }

    [Fact]
    public async Task RF12_RF13_RF15_RF18_RF19_NotasYAuditoriaRespetanPermisos()
    {
        var receptionist = await Token("recepcion1");
        var professional = await Token("profesional1");
        var another = await Token("profesional1b");
        var admin = await Token("admin1");
        var created = await Json(await Send(HttpMethod.Post, "/api/citas", receptionist, Booking(Start(DateOnly.FromDateTime(DateTime.UtcNow.AddDays(-1)), 8))), HttpStatusCode.Created);
        var id = created.GetProperty("id").GetGuid();
        await Json(await Send(HttpMethod.Post, $"/api/citas/{id}/desenlace", receptionist, new { estado = "atendida" }), HttpStatusCode.OK);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Post, $"/api/citas/{id}/nota", another, new { contenido = "No autorizado" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Post, $"/api/citas/{id}/nota", admin, new { contenido = "No autorizado" })).StatusCode);
        await Json(await Send(HttpMethod.Post, $"/api/citas/{id}/nota", professional, new { contenido = "Nota de prueba" }), HttpStatusCode.Created);
        await Json(await Send(HttpMethod.Get, $"/api/citas/{id}/nota", professional), HttpStatusCode.OK);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(HttpMethod.Get, "/api/auditoria", receptionist)).StatusCode);
        var logs = await Json(await Send(HttpMethod.Get, $"/api/auditoria?pacienteId={Patient}", admin), HttpStatusCode.OK);
        Assert.Contains(logs.EnumerateArray(), l => l.GetProperty("accion").GetString() == "nota.escritura");
        Assert.Contains(logs.EnumerateArray(), l => l.GetProperty("accion").GetString() == "nota.lectura");
        var check = await Json(await Send(HttpMethod.Get, "/api/auditoria/verificar", admin), HttpStatusCode.OK);
        Assert.True(check.GetProperty("valida").GetBoolean());
    }

    [Fact]
    public async Task RF10_ReprogramacionFallidaConservaLaReservaOriginal()
    {
        var token = await Token("recepcion1");
        var start = Start(Day.AddDays(5), 8);
        var a = await Json(await Send(HttpMethod.Post, "/api/citas", token, Booking(start)), HttpStatusCode.Created);
        var b = await Json(await Send(HttpMethod.Post, "/api/citas", token, Booking(start.AddHours(1), patient: Id('5', 102))), HttpStatusCode.Created);
        var id = a.GetProperty("id").GetGuid();
        Assert.Equal(HttpStatusCode.Conflict, (await Send(HttpMethod.Post, $"/api/citas/{id}/reprogramar", token,
            new { profesionalId = Professional, servicioId = Service, inicio = start.AddHours(1) })).StatusCode);
        var original = await Json(await Send(HttpMethod.Get, $"/api/citas/{id}", token), HttpStatusCode.OK);
        Assert.Equal("reservada", original.GetProperty("estado").GetString());
        Assert.Equal(start, original.GetProperty("inicio").GetDateTimeOffset());
        await Cancel(id, token);
        await Cancel(b.GetProperty("id").GetGuid(), token);
    }

    [Fact]
    public async Task I5_I6_BaseAplicaRLSYRechazaMutacionesDeAuditoria()
    {
        var connectionString = new NpgsqlConnectionStringBuilder
        {
            Host = Environment.GetEnvironmentVariable("POSTGRES_HOST") ?? "bd",
            Port = int.Parse(Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432"),
            Database = Environment.GetEnvironmentVariable("POSTGRES_DB") ?? "restaurantdb",
            Username = Environment.GetEnvironmentVariable("POSTGRES_USER") ?? "medicitas_app",
            Password = Environment.GetEnvironmentVariable("POSTGRES_PASSWORD") ?? "medicitas-local-pass"
        }.ConnectionString;
        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync();
        await using (var transaction = await conn.BeginTransactionAsync())
        {
            await new NpgsqlCommand($"SET LOCAL ROLE med_reader; SELECT set_config('app.tenant_id','{Clinic}',true)", conn, transaction).ExecuteNonQueryAsync();
            var count = (long)(await new NpgsqlCommand($"SELECT count(*) FROM med.pacientes WHERE clinica_id <> '{Clinic}'", conn, transaction).ExecuteScalarAsync())!;
            Assert.Equal(0, count);
        }
        foreach (var sql in new[] { "UPDATE med.auditoria SET accion = 'alterada'", "DELETE FROM med.auditoria", "TRUNCATE med.auditoria" })
        {
            await using var tx = await conn.BeginTransactionAsync();
            await new NpgsqlCommand("SET LOCAL ROLE med_auditor", conn, tx).ExecuteNonQueryAsync();
            var exception = await Assert.ThrowsAsync<PostgresException>(() => new NpgsqlCommand(sql, conn, tx).ExecuteNonQueryAsync());
            Assert.Equal("42501", exception.SqlState);
        }
    }
}
