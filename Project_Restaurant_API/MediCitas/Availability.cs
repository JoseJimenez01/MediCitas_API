using System.Text.Json;
using StackExchange.Redis;

namespace Project_Restaurant_API.MediCitas;

public sealed record Slot(int ProfesionalId, DateTimeOffset Inicio, DateTimeOffset Fin);
public sealed record AvailabilityResult(int ProfesionalId, int ServicioId, DateOnly Fecha, bool CacheHit, List<Slot> Espacios);

public sealed class Availability(IConnectionMultiplexer redis, ILogger<Availability> logger)
{
    public static bool Overlaps(DateTimeOffset start, DateTimeOffset end, DateTimeOffset otherStart, DateTimeOffset otherEnd)
        => start < otherEnd && otherStart < end;

    public static string BuildHashKey(int clinicaId, int profesionalId)
        => $"med:disp:{clinicaId}:{profesionalId}";

    public static string BuildFieldKey(int servicioId, DateOnly fecha)
        => $"{servicioId}:{fecha:yyyy-MM-dd}";

    public async Task<AvailabilityResult> GetAsync(MedicalSession session, int profesionalId, int servicioId, DateOnly fecha, CancellationToken ct)
    {
        var clinicaId = session.Identity.ClinicaId ?? throw new DomainException(403, "Contexto de clinica requerido.");
        var hashKey = BuildHashKey(clinicaId, profesionalId);
        var fieldKey = BuildFieldKey(servicioId, fecha);

        try
        {
            var db = redis.GetDatabase();
            var cached = await db.HashGetAsync(hashKey, fieldKey);
            if (cached.HasValue)
            {
                var parsed = JsonSerializer.Deserialize<List<Slot>>(cached.ToString());
                if (parsed is not null)
                    return new AvailabilityResult(profesionalId, servicioId, fecha, true, parsed);
            }
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException or JsonException)
        {
            logger.LogWarning("Consulta de cache Redis no disponible: {Type}", ex.GetType().Name);
        }

        var rows = await session.CallCursorAsync(
            "SP_ConsultarDisponibilidadProfesional",
            ct,
            ("userName", session.Identity.NombreUsuario),
            ("idProfesional", profesionalId),
            ("idServicio", servicioId),
            ("fecha", fecha));

        var slots = new List<Slot>(rows.Count);
        foreach (var row in rows)
        {
            var start = row["horaInicio"] switch
            {
                DateTimeOffset dto => dto,
                DateTime dt => new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc)),
                _ => throw new DomainException(500, "Formato de hora_inicio inesperado.")
            };
            var end = row["horaFin"] switch
            {
                DateTimeOffset dto => dto,
                DateTime dt => new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc)),
                _ => throw new DomainException(500, "Formato de hora_fin inesperado.")
            };
            slots.Add(new Slot(profesionalId, start, end));
        }

        try
        {
            var db = redis.GetDatabase();
            await db.HashSetAsync(hashKey, fieldKey, JsonSerializer.Serialize(slots));
            await db.KeyExpireAsync(hashKey, TimeSpan.FromMinutes(5));
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            logger.LogWarning("Escritura de cache Redis no disponible: {Type}", ex.GetType().Name);
        }

        return new AvailabilityResult(profesionalId, servicioId, fecha, false, slots);
    }

    public async Task InvalidateProfessionalAsync(int clinicaId, int profesionalId)
    {
        try
        {
            var db = redis.GetDatabase();
            await db.KeyDeleteAsync(BuildHashKey(clinicaId, profesionalId));
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            logger.LogWarning("Invalidacion de cache Redis no disponible: {Type}", ex.GetType().Name);
        }
    }

    public async Task InvalidateProfessionalsAsync(int clinicaId, IEnumerable<int> profesionalIds)
    {
        foreach (var id in profesionalIds.Distinct())
            await InvalidateProfessionalAsync(clinicaId, id);
    }
}
