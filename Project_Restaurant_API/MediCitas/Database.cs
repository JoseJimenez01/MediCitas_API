using System.Data;
using System.Reflection;
using System.Security.Claims;
using Npgsql;
using NpgsqlTypes;

namespace Project_Restaurant_API.MediCitas;

public sealed record Identity(Guid Id, Guid? ClinicaId, string Rol, bool Activo, Guid? ProfesionalId);

public sealed class DomainException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

public sealed class MedicalDatabase(IConfiguration config)
{
    public string ConnectionString { get; } = Connection(config);

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
            Timeout = 5,
            CommandTimeout = 30,
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
                var assembly = Assembly.GetExecutingAssembly();
                foreach (var resource in assembly.GetManifestResourceNames().Where(x => x.EndsWith(".sql")).Order())
                {
                    using var stream = assembly.GetManifestResourceStream(resource)!;
                    using var reader = new StreamReader(stream);
                    await new NpgsqlCommand(await reader.ReadToEndAsync(), conn, tx) { CommandTimeout = 60 }.ExecuteNonQueryAsync();
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
                await new NpgsqlCommand($"GRANT med_reader, med_writer, med_clinical, med_auditor, med_platform, med_legacy TO {identifier}", conn, tx).ExecuteNonQueryAsync();
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
        if (!Guid.TryParse(principal.FindFirstValue("sub"), out var subject)) throw new DomainException(403, "Identidad no asociada.");
        await using var conn = new NpgsqlConnection(ConnectionString);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await new NpgsqlCommand("SET LOCAL ROLE med_reader", conn, tx).ExecuteNonQueryAsync(ct);
        await using var command = new NpgsqlCommand("SELECT * FROM med.resolve_identity(@subject)", conn, tx);
        command.Parameters.AddWithValue("subject", subject);
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) throw new DomainException(403, "Identidad no asociada.");
        var identity = new Identity(reader.GetGuid(0), reader.IsDBNull(1) ? null : reader.GetGuid(1),
            reader.GetString(2), reader.GetBoolean(3), reader.IsDBNull(4) ? null : reader.GetGuid(4));
        if (!identity.Activo || !principal.IsInRole(identity.Rol)) throw new DomainException(403, "Usuario inactivo o rol no autorizado.");
        return identity;
    }

    public async Task<MedicalSession> OpenAsync(Identity identity, CancellationToken ct, bool auditor = false, Guid? tenant = null)
    {
        var session = new MedicalSession(new NpgsqlConnection(ConnectionString), identity);
        try
        {
            await session.Connection.OpenAsync(ct);
            session.Transaction = await session.Connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
            var role = auditor ? "med_auditor" : identity.Rol switch
            {
                "platform-admin" => "med_platform",
                "professional" => "med_clinical",
                _ => "med_writer"
            };
            await session.ExecuteAsync($"SET LOCAL ROLE {role}", ct);
            await session.ExecuteAsync("SELECT set_config('app.tenant_id', @tenant, true), set_config('app.subject', @subject, true)", ct,
                ("tenant", (tenant ?? identity.ClinicaId)?.ToString() ?? ""), ("subject", identity.Id.ToString()));
            if ((tenant ?? identity.ClinicaId) is Guid clinic)
                await session.ExecuteAsync("SELECT pg_advisory_xact_lock(hashtextextended(@tenant, 42))", ct, ("tenant", clinic.ToString()));
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }
}

public sealed class MedicalSession(NpgsqlConnection connection, Identity identity) : IAsyncDisposable
{
    public NpgsqlConnection Connection { get; } = connection;
    public NpgsqlTransaction Transaction { get; set; } = null!;
    public Identity Identity { get; } = identity;

    public NpgsqlCommand Command(string sql, params (string Name, object? Value)[] parameters)
    {
        var cmd = new NpgsqlCommand(sql, Connection, Transaction);
        foreach (var (name, value) in parameters)
        {
            if (value is null) cmd.Parameters.Add(new NpgsqlParameter(name, NpgsqlDbType.Unknown) { Value = DBNull.Value });
            else cmd.Parameters.AddWithValue(name, value);
        }
        return cmd;
    }

    public async Task<int> ExecuteAsync(string sql, CancellationToken ct, params (string Name, object? Value)[] parameters)
    {
        await using var cmd = Command(sql, parameters);
        return await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<List<Dictionary<string, object?>>> QueryAsync(string sql, CancellationToken ct, params (string Name, object? Value)[] parameters)
    {
        await using var cmd = Command(sql, parameters);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var result = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>();
            for (var i = 0; i < reader.FieldCount; i++)
            {
                var parts = reader.GetName(i).Split('_');
                var name = parts[0] + string.Concat(parts.Skip(1).Select(p => char.ToUpperInvariant(p[0]) + p[1..]));
                row[name] = reader.IsDBNull(i) ? null : reader.GetDataTypeName(i) switch
                {
                    "date" => reader.GetFieldValue<DateOnly>(i),
                    "time without time zone" => reader.GetFieldValue<TimeOnly>(i),
                    _ => reader.GetValue(i)
                };
            }
            result.Add(row);
        }
        return result;
    }

    public async Task<Dictionary<string, object?>> OneAsync(string sql, CancellationToken ct, params (string Name, object? Value)[] parameters)
        => (await QueryAsync(sql, ct, parameters)).FirstOrDefault() ?? throw new DomainException(404, "Recurso no encontrado.");

    public Task AuditAsync(Guid patient, string action, Guid resource, CancellationToken ct)
        => ExecuteAsync("SELECT med.auditar(@patient, @action, @resource)", ct, ("patient", patient), ("action", action), ("resource", resource));

    public Task CommitAsync(CancellationToken ct) => Transaction.CommitAsync(ct);

    public async ValueTask DisposeAsync()
    {
        if (Transaction is not null) await Transaction.DisposeAsync();
        await Connection.DisposeAsync();
    }
}
