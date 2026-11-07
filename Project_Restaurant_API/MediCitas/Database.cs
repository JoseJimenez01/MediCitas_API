using System.Data;
using System.Net;
using System.Reflection;
using System.Security.Claims;
using Npgsql;
using NpgsqlTypes;

namespace Project_Restaurant_API.MediCitas;

public sealed record Identity(
    int Id,
    int? ClinicaId,
    int IdRol,
    string Rol,
    string NombreUsuario,
    string Correo,
    bool Activo,
    int? ProfesionalId,
    string TokenSub);

public sealed class DomainException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

public sealed class MedicalDatabase(IConfiguration config)
{
    public string ConnectionString { get; } = Connection(config);

    public static string MapRoleName(int idRol) => idRol switch
    {
        1 => "platform-admin",
        2 => "clinic-admin",
        3 => "reception",
        4 => "professional",
        _ => throw new DomainException(403, "Rol no reconocido.")
    };

    public static int MapRoleId(string rol) => rol switch
    {
        "platform-admin" => 1,
        "clinic-admin" => 2,
        "reception" => 3,
        "professional" => 4,
        _ => throw new DomainException(400, "Rol invalido.")
    };

    public static string MapDatabaseRole(string rol) => rol switch
    {
        "platform-admin" => "app_plataforma",
        "clinic-admin" => "app_admin_clinica",
        "reception" => "app_recepcion",
        "professional" => "app_profesional",
        _ => throw new DomainException(403, "Rol no autorizado.")
    };

    public static string Connection(IConfiguration config, bool bootstrap = false)
    {
        var supplied = bootstrap ? config["DB_BOOTSTRAP_CONNECTION"] : config.GetConnectionString("Default");
        if (!string.IsNullOrWhiteSpace(supplied)) return supplied;
        return new NpgsqlConnectionStringBuilder
        {
            Host = config["POSTGRES_HOST"] ?? "bd",
            Port = int.TryParse(config["POSTGRES_PORT"], out var port) ? port : 5432,
            Database = config["POSTGRES_DB"] ?? "restaurantdb",
            Username = bootstrap ? config["DB_BOOTSTRAP_USER"] ?? "postgres" : config["POSTGRES_USER"] ?? "medicitas_app",
            Password = bootstrap ? config["DB_BOOTSTRAP_PASSWORD"] ?? "" : config["POSTGRES_PASSWORD"] ?? "",
            Timeout = 10,
            CommandTimeout = 60,
            IncludeErrorDetail = false
        }.ConnectionString;
    }

    public static async Task InitializeAsync(IConfiguration config, ILogger logger)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                await using var conn = new NpgsqlConnection(Connection(config, true));
                await conn.OpenAsync();
                await using var tx = await conn.BeginTransactionAsync();
                await new NpgsqlCommand("SELECT pg_advisory_xact_lock(782375628)", conn, tx).ExecuteNonQueryAsync();

                var schemaExists = (bool)(await new NpgsqlCommand(
                    "SELECT to_regclass('public.clinica') IS NOT NULL", conn, tx).ExecuteScalarAsync())!;

                if (!schemaExists)
                {
                    var assembly = Assembly.GetExecutingAssembly();
                    foreach (var resource in assembly.GetManifestResourceNames().Where(x => x.EndsWith(".sql")).Order())
                    {
                        using var stream = assembly.GetManifestResourceStream(resource)!;
                        using var reader = new StreamReader(stream);
                        var sql = await reader.ReadToEndAsync();
                        await new NpgsqlCommand(sql, conn, tx) { CommandTimeout = 180 }.ExecuteNonQueryAsync();
                    }
                }

                var user = config["POSTGRES_USER"] ?? "medicitas_app";
                if (user == (config["DB_BOOTSTRAP_USER"] ?? "postgres"))
                    throw new InvalidOperationException("La aplicacion requiere un usuario distinto del administrador de PostgreSQL.");
                var password = config["POSTGRES_PASSWORD"];
                if (string.IsNullOrWhiteSpace(password)) throw new InvalidOperationException("POSTGRES_PASSWORD es obligatorio.");
                await using var exists = new NpgsqlCommand("SELECT EXISTS(SELECT FROM pg_roles WHERE rolname = @user)", conn, tx);
                exists.Parameters.AddWithValue("user", user);
                var operation = (bool)(await exists.ExecuteScalarAsync())! ? "ALTER" : "CREATE";
                var identifier = new NpgsqlCommandBuilder().QuoteIdentifier(user);
                var literal = "'" + password.Replace("'", "''") + "'";
                await new NpgsqlCommand($"{operation} ROLE {identifier} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS PASSWORD {literal}", conn, tx).ExecuteNonQueryAsync();
                await new NpgsqlCommand($"GRANT app_plataforma, app_medicitas, app_admin_clinica, app_recepcion, app_profesional TO {identifier}", conn, tx).ExecuteNonQueryAsync();
                await tx.CommitAsync();
                return;
            }
            catch (NpgsqlException ex) when (attempt < 29 && ex.IsTransient)
            {
                logger.LogWarning("Base no disponible, intento {Attempt}: {Code}", attempt + 1, ex.SqlState);
                await Task.Delay(TimeSpan.FromSeconds(2));
            }
        }
    }

    public async Task<Identity> ResolveAsync(ClaimsPrincipal principal, CancellationToken ct)
    {
        var subject = principal.FindFirstValue("sub");
        if (string.IsNullOrWhiteSpace(subject)) throw new DomainException(403, "Identidad no asociada.");
        await using var conn = new NpgsqlConnection(ConnectionString);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await new NpgsqlCommand("SET LOCAL ROLE app_medicitas", conn, tx).ExecuteNonQueryAsync(ct);
        await using var cmd = new NpgsqlCommand(
            "CALL SP_ResolverIdentidad(@sub, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)", conn, tx);
        cmd.Parameters.AddWithValue("sub", subject);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) throw new DomainException(403, "Identidad no asociada.");
        var result = reader.GetInt32(7);
        if (result != 0) throw new DomainException(403, "Identidad no asociada.");
        var idUsuario = reader.GetInt32(0);
        int? idClinica = reader.IsDBNull(1) ? null : reader.GetInt32(1);
        var idRol = reader.GetInt32(2);
        var rol = MapRoleName(idRol);
        var nombre = reader.GetString(3);
        var correo = reader.GetString(4);
        var activo = reader.GetBoolean(5);
        int? idProfesional = reader.IsDBNull(6) ? null : reader.GetInt32(6);
        await reader.CloseAsync();
        await tx.CommitAsync(ct);
        if (!activo || !principal.IsInRole(rol)) throw new DomainException(403, "Usuario inactivo o rol no autorizado.");
        return new Identity(idUsuario, idClinica, idRol, rol, nombre, correo, activo, idProfesional, subject);
    }

    public async Task<MedicalSession> OpenAsync(Identity identity, CancellationToken ct, int? tenantOverride = null, IPAddress? clientIp = null)
    {
        var session = new MedicalSession(new NpgsqlConnection(ConnectionString), identity, clientIp);
        try
        {
            await session.Connection.OpenAsync(ct);
            session.Transaction = await session.Connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
            var dbRole = MapDatabaseRole(identity.Rol);
            await session.ExecuteAsync($"SET LOCAL ROLE {dbRole}", ct);
            var clinic = tenantOverride ?? identity.ClinicaId;
            await session.ExecuteAsync("SELECT set_config('app.id_clinica', @tenant, true)", ct,
                ("tenant", clinic?.ToString() ?? ""));
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }
}

public sealed class MedicalSession(NpgsqlConnection connection, Identity identity, IPAddress? clientIp = null) : IAsyncDisposable
{
    public NpgsqlConnection Connection { get; } = connection;
    public NpgsqlTransaction Transaction { get; set; } = null!;
    public Identity Identity { get; } = identity;
    public IPAddress ClientIp { get; } = clientIp is null || clientIp.IsIPv4MappedToIPv6
        ? (clientIp?.MapToIPv4() ?? IPAddress.Loopback)
        : clientIp;

    public NpgsqlCommand Command(string sql, params (string Name, object? Value)[] parameters)
    {
        var cmd = new NpgsqlCommand(sql, Connection, Transaction);
        foreach (var (name, value) in parameters)
        {
            if (value is null) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.Unknown) { Value = DBNull.Value });
            else if (value is DateOnly dateOnly) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.Date) { Value = dateOnly });
            else if (value is TimeOnly timeOnly) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.Time) { Value = timeOnly });
            else if (value is DateTime dateTime) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.TimestampTz) { Value = DateTime.SpecifyKind(dateTime, DateTimeKind.Utc) });
            else if (value is DateTimeOffset dto) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.TimestampTz) { Value = dto.UtcDateTime });
            else if (value is IPAddress ip) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.Inet) { Value = ip });
            else cmd.Parameters.AddWithValue(name, value);
        }
        return cmd;
    }

    public async Task<int> ExecuteAsync(string sql, CancellationToken ct, params (string Name, object? Value)[] parameters)
    {
        await using var cmd = Command(sql, parameters);
        return await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<Dictionary<string, object?>> CallOutAsync(
        string procedureName,
        int outCount,
        CancellationToken ct,
        params (string Name, object? Value)[] inParameters)
    {
        var placeholders = inParameters.Select(p => "@" + p.Name).Concat(Enumerable.Repeat("NULL", outCount));
        var sql = $"CALL {procedureName}({string.Join(", ", placeholders)})";
        var row = (await ReadRowsAsync(sql, ct, inParameters)).FirstOrDefault()
            ?? throw new DomainException(500, $"El procedimiento {procedureName} no devolvio resultado.");
        var outResult = Convert.ToInt32(row["outresult"] ?? 500);
        if (outResult != 0)
        {
            await CommitAsync(ct);
            throw MapProcedureError(outResult, procedureName);
        }
        return row;
    }

    public async Task<List<Dictionary<string, object?>>> CallCursorAsync(
        string procedureName,
        CancellationToken ct,
        params (string Name, object? Value)[] inParameters)
    {
        var placeholders = inParameters.Select(p => "@" + p.Name).Concat(["NULL", "NULL"]);
        var sql = $"CALL {procedureName}({string.Join(", ", placeholders)})";
        var header = (await ReadRowsAsync(sql, ct, inParameters)).FirstOrDefault()
            ?? throw new DomainException(500, $"El procedimiento {procedureName} no devolvio cursor.");
        var outResult = Convert.ToInt32(header["outresult"] ?? 500);
        if (outResult != 0)
        {
            await CommitAsync(ct);
            throw MapProcedureError(outResult, procedureName);
        }
        var cursorName = header["outcursor"]?.ToString();
        if (string.IsNullOrWhiteSpace(cursorName)) return [];
        var escaped = "\"" + cursorName.Replace("\"", "\"\"") + "\"";
        var rows = await ReadRowsAsync($"FETCH ALL FROM {escaped}", ct);
        await ExecuteAsync($"CLOSE {escaped}", ct);
        return rows;
    }

    public async Task<Dictionary<string, object?>> CallCursorOneAsync(
        string procedureName,
        CancellationToken ct,
        params (string Name, object? Value)[] inParameters)
    {
        var rows = await CallCursorAsync(procedureName, ct, inParameters);
        return rows.FirstOrDefault() ?? throw new DomainException(404, "Recurso no encontrado.");
    }

    private async Task<List<Dictionary<string, object?>>> ReadRowsAsync(
        string sql,
        CancellationToken ct,
        params (string Name, object? Value)[] parameters)
    {
        await using var cmd = Command(sql, parameters);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var result = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
            {
                var rawName = reader.GetName(i);
                var parts = rawName.Split('_');
                var camel = parts[0] + string.Concat(parts.Skip(1).Select(p => p.Length > 0 ? char.ToUpperInvariant(p[0]) + p[1..] : ""));
                var val = reader.IsDBNull(i) ? null : reader.GetDataTypeName(i) switch
                {
                    "date" => reader.GetFieldValue<DateOnly>(i),
                    "time without time zone" => reader.GetFieldValue<TimeOnly>(i),
                    "inet" => reader.GetFieldValue<IPAddress>(i).ToString(),
                    _ => reader.GetValue(i)
                };
                row[camel] = val;
            }
            result.Add(row);
        }
        return result;
    }

    private static DomainException MapProcedureError(int code, string procedureName) => code switch
    {
        403 => new DomainException(403, $"Acceso denegado en {procedureName}."),
        404 => new DomainException(404, "Recurso no encontrado."),
        409 => new DomainException(409, "Conflicto con el estado actual o solapamiento de intervalo."),
        422 => new DomainException(400, "La solicitud incumple las reglas de validacion del dominio."),
        _ => new DomainException(500, "No se pudo completar la operacion.")
    };

    public Task CommitAsync(CancellationToken ct) => Transaction.CommitAsync(ct);

    public async ValueTask DisposeAsync()
    {
        if (Transaction is not null) await Transaction.DisposeAsync();
        await Connection.DisposeAsync();
    }
}
